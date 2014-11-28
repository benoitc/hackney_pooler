-module(hackney_pooler).

-export([new_pool/2, rm_pool/1, pool_stats/1]).
-export([request/3, request/4, request/5, request/6, request/7,
         async_request/6, async_request/7, async_request/8]).

%% internal methods
-export([istart_link/2, init/3,
         system_continue/3, system_terminate/4, system_code_change/4]).

-record(state, {parent, hpools, name}).


-define(HCALL(Pid, Req), {'$hackney_call', Pid, Req}).
-define(HCAST(Pid, Req), {'$hackney_cast', Pid, Req}).

%% @doc Start a new pool described by the proplist `PoolConfig'. The
%% following keys are required in the proplist:
%%
%% <dl>
%% <dt>`init_count'</dt>
%% <dd>Number of members to add to the pool at start. When the pool is
%% started, `init_count' members will be started in parallel.</dd>
%% <dt>`max_count'</dt>
%% </dl>
%%
%% In addition, you can specify any of the following optional
%% configuration options:
%%
%% <dl>
%% <dt>`max_connections'</dt>
%% <dd>An integer giving the max number of connections in a pool used in
%% {@link request/7} and {@link async_request/8}.</dd>
%% <dt>`concurrency'</dt>
%% <dd>Make {@link request/7} and {@link async_request/8} concurrent. It set
%% the number of connections pool (depedending of the number of I/O threads) and the default number of of connections per
%% pools. Using multiple pool will allows the worker to work quite in parallel.</dd>
%% %% <dt>`{concurrency, N}'</dt>
%% <dd>Like above, make {@link request/7} and {@link async_request/8} concurrent. N is an
%% integer giving the number of connections pool.</dd>
%% <dt>`cull_interval'</dt>
%% <dd>Time between checks for stale pool members. Specified as
%% `{Time, Unit}' where `Time' is a non-negative integer and `Unit' is
%% one of `min', `sec', `ms', or `mu'. The default value of `{1, min}'
%% triggers a once per minute check to remove members that have not
%% been accessed in `max_age' time units. Culling can be disabled by
%% specifying a zero time vaule (e.g. `{0, min}'. Culling will also be
%% disabled if `init_count' is the same as `max_count'.</dd>
%% <dt>`max_age'</dt>
%% <dd>Members idle longer than `max_age' time units are removed from
%% the pool when stale checking is enabled via
%% `cull_interval'. Culling of idle members will never reduce the pool
%% below `init_count'. The value is specified as `{Time, Unit}'. Note
%% that timers are not set on individual pool members and may remain
%% in the pool beyond the configured `max_age' value since members are
%% only removed on the interval configured via `cull_interval'. The
%% default value is `{30, sec}'.</dd>
%% <dt>`member_start_timeout'</dt>
%% <dd>Time limit for member starts. Specified as `{Time,
%% Unit}'. Defaults to `{1, min}'.</dd>
%% </dl>
new_pool(PoolName, Config) ->
    Concurrency = proplists:get_value(concurrency, Config),
    %% get the number of hackney pools to launch
    NPool = npool(Concurrency),
    %% get the number of connections / hackney pools
    MaxConn = maxconn(Concurrency, NPool, Config),

    %% start pools depending on the concurrency
    HConfig =  [{max_connections, MaxConn}],
    PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
    HPools = lists:foldl(fun(_, Acc) ->
                                 Name = {PoolName, make_ref()},
                                 %% start Hackney pool
                                 ok = PoolHandler:start_pool(Name, HConfig),
                                 [Name | Acc]
                         end, [], lists:seq(1, NPool)),

    %% start worker pool
    Config1 = [{name, PoolName} |Config],
    PoolConfig = Config1 ++ [{start_mfa,
                              {?MODULE, istart_link, [HPools, PoolName]}}],
    pooler:new_pool(PoolConfig).

%% @doc Terminate the named pool.
rm_pool(Name) ->
    pooler:rm_pool(Name),
    %% stop hackney pools
    PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
    HPools = [{Name, Ref} || [Ref] <- ets:match(hackney_pool,
                                                {{Name, '$1'}, '_'})],
    lists:foreach(fun(HPool) ->
                          catch PoolHandler:stop_pool(HPool)
                  end, HPools),
    ok.
%% @doc Obtain runtime state info for all pools.
pool_stats(Name) ->
    PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
    HPools = [{Name, Ref} || [Ref] <- ets:match(hackney_pool, {{Name, '$1'}, '_'})],
    [{workers, pooler:pool_stats(Name)},
     {hpools, [{PoolHandler:find_pool(P), PoolHandler:count(P)}
               || P <- HPools]}].


%% @doc make a request
-spec request(atom(), term(), binary()|list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL) ->
    request(PoolName, Method, URL, [], <<>>, []).

%% @doc make a request
-spec request(atom(), term(), binary()|list(), list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers) ->
    request(PoolName, Method, URL, Headers, <<>>, []).

%% @doc make a request
-spec request(atom(), term(), binary()|list(), list(), term())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers, Body) ->
    request(PoolName, Method, URL, Headers, Body, []).


-spec request(atom(), term(), binary()|list(), list(), term(), list())
    -> {ok, integer(), list(), binary()} | {error, term()}.
request(PoolName, Method, URL, Headers, Body, Options) ->
    request(PoolName, Method, URL, Headers, Body, Options, 0).

request(PoolName, Method, URL, Headers, Body, Options, Timeout) ->
    case pooler:take_member(PoolName, Timeout) of
        error_no_members -> error_no_members;
        Proc ->
            try
                req(Proc, {request, Method, URL, Headers, Body, Options})
            after
                pooler:return_member(PoolName, Proc, ok)
            end
    end.

%% @doc make an async request and don't wit for the result
-spec async_request(atom(), term(), binary()|list(), list(), term(),
                    list()) -> ok.
async_request(PoolName, Method, URL, Headers, Body, Options) ->
    async_request(PoolName, nil, Method, URL, Headers, Body, Options).


%% @doc make an async request and retrieve the results as a message in a
%% process or by using a function.
-spec async_request(atom(), term(), term(), binary()|list(), list(), term(),
                    list()) -> ok.
async_request(PoolName, To, Method, URL, Headers, Body, Options) ->
    async_request(PoolName, To, Method, URL, Headers, Body, Options, 0).

-spec async_request(atom(), term(), term(), binary()|list(), list(), term(),
                    list(), integer()) -> ok.
async_request(PoolName, To, Method, URL, Headers, Body, Options, Timeout) ->
    case pooler:take_member(PoolName, Timeout) of
        error_no_members -> error_no_members;
        Proc ->
            cast_req(Proc, To, {request, Method, URL, Headers, Body, Options}),
            ok
    end.

req(Proc, R) ->
    Ref = erlang:monitor(process, Proc),
    Proc ! ?HCALL(self(), R),
    receive
        {'DOWN', Ref, process, Proc, Info} ->
            error_logger:format("** hackney_pooler: worker down"
                                ": ~w~n", [Info]),
            badarg;
        {Proc, Reply} ->
            erlang:demonitor(Ref, [flush]),
            Reply
    end.


cast_req(Proc, To, R) ->
    Msg = ?HCAST(To, R),
    case catch erlang:send(Proc, Msg, [noconnect]) of
        noconnect ->
            spawn(erlang, send, [Proc, Msg]);
        Other ->
            Other
    end.


istart_link(HPools, Name) ->
    {ok, proc_lib:spawn_link(hackney_pooler, init, [self(), HPools, Name])}.


init(Parent, HPools, Name) ->
    process_flag(trap_exit, true),
    pooler_loop(#state{parent=Parent, hpools=HPools, name=Name}).



pooler_loop(#state{parent=Parent, hpools=HPools, name=PoolName}=State) ->
    receive
        ?HCALL(From, {request, Method, Url, Headers, Body, Options}) ->
            {HPool, HPools2} = choose_pool(HPools),
            do_request(From, HPool, Method, Url, Headers, Body, Options),
            pooler_loop(State#state{hpools=HPools2});
        ?HCAST(To, {request, Method, Url, Headers, Body, Options}) ->
            {HPool, HPools2} = choose_pool(HPools),
            do_async_request(PoolName, To, HPool, Method, Url, Headers, Body,
                             Options),
            pooler:return_member(PoolName, self(), ok),
            pooler_loop(State#state{hpools=HPools2});
        {'EXIT', Parent, Reason} ->
            terminate(Reason, State),
            exit(Reason);
        {system, From, Req} ->
            sys:handle_system_msg(Req, From, Parent, ?MODULE, [], State);
        Message ->
            error_logger:format("** hackney_pooler: unexpected message"
                                "(ignored): ~w~n", [Message]),
            pooler_loop(State)
    end.


npool(true) ->
    %% if concurrency is set to true then we
    %% launch, then we launch N pools where 2 * N +
    %% 2 is the number of threads with a min of 1.
    %% The number of connections is then equally
    %% shared between them
    erlang:max(1, trunc((erlang:system_info(thread_pool_size) - 1) / 2));
npool(N) when is_integer(N) ->
    N;
npool(_) ->
    1.


maxconn(Concurrency, NPool, Options)
  when Concurrency =:= true orelse is_integer(Concurrency) ->
    case proplists:get_value(max_connections, Options) of
        N when is_integer(N) -> N;
        _ ->
            MaxCount = proplists:get_value(max_count, Options, 50),
            erlang:max(10, trunc(MaxCount / NPool) + 1)
    end;
maxconn(_, _NPool, Options) ->
    proplists:get_value(max_count, Options, 50).


do_request(From, HPool,  Method, Url, Headers, Body, Options) ->
    %% pass the pool to the config.
    Options1 = [{pool, HPool} | Options],
    %% do the request
    Reply = case hackney:request(Method, Url, Headers, Body, Options1) of
                {ok, Status, RespHeaders, Ref} ->
                    erlang:put(req, Ref),
                    case hackney:body(Ref) of
                        {ok, RespBody} ->
                            erlang:erase(req),
                            {ok, Status, RespHeaders, RespBody};
                        Error -> Error
                    end;
                {ok, Status, RespHeaders} ->
                    {ok, Status, RespHeaders, <<>>};
                Error ->
                    Error
            end,
    %% send the reply
    From ! {self(), Reply},
    ok.

do_async_request(PoolName, To, HPool,  Method, Url, Headers, Body, Options) ->
    %% pass the pool to the config.
    Options1 = [{pool, HPool} | Options],
    %% do the request
    Reply = case hackney:request(Method, Url, Headers, Body, Options1) of
                {ok, Status, RespHeaders, Ref} ->
                    erlang:put(req, Ref),
                    case hackney:body(Ref) of
                        {ok, RespBody} ->
                            erlang:erase(req),
                            {ok, Status, RespHeaders, RespBody};
                        Error -> Error
                    end;
                {ok, Status, RespHeaders} ->
                    {ok, Status, RespHeaders, <<>>};
                Error ->
                    Error
            end,

    try
        send_async(To, PoolName, Reply)
    catch
        _:_ ->
            error_logger:format("** hackney_pooler (async req) ~p: "
                                "unexpected error (ignored): ~w~n", [PoolName,
                                                    erlang:get_stacktrace()])
    end,
    ok.


%% balance pool
choose_pool([HPool]=HPools) ->
    {HPool, HPools};
choose_pool([HPool | Rest]) ->
    {HPool, Rest ++ [HPool]}.

send_async(nil, _PoolName, _Reply) ->
    ok;
send_async(Pid, PoolName, Reply) when is_pid(Pid) ->
    Pid ! {hpool, {PoolName, Reply}};
send_async(Fun, PoolName, Reply) when is_function(Fun) ->
    Fun({PoolName, Reply});
send_async({Fun, Acc}, PoolName, Reply) when is_function(Fun) ->
    Fun({PoolName, Reply}, Acc);
send_async(To, PoolName, _Reply) ->
    error_logger:format("** ~p hackney_pooler: unexpected async callback"
                                "(ignored): ~w~n", [PoolName, To]),
    ok.

terminate(_Reason, _State) ->
    %% if a request is running, force close
    case erlang:get(req) of
        undefined -> ok;
        Ref ->
            catch hackney:close(Ref),
            ok
    end,
    ok.


%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(_Parent, _, State) ->
    pooler_loop(State).

system_terminate(Reason, _Parent, _, State) ->
    terminate(Reason, State),
    exit(Reason).

%%-----------------------------------------------------------------
%% Code for upgrade.
%%-----------------------------------------------------------------
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.
