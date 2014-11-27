-module(hackney_pooler).

-export([new_pool/2, rm_pool/1, pool_stats/1]).
-export([request/3, request/4, request/5, request/6,
         async_request/6, async_request/7]).

%% internal methods
-export([istart_link/2, init/3,
         system_continue/3, system_terminate/4, system_code_change/4]).

-record(state, {parent, hpools, name}).


-define(HCALL(Pid, Req), {'$hackney_call', Pid, Req}).
-define(HCAST(Pid, Req), {'$hackney_cast', Pid, Req}).

new_pool(PoolName, Config) ->
    MaxCount = proplists:get_value(max_count, Config, 50),
    %% get the number of hackney pools to launch
    {NPool, MaxConn} = case proplists:get_value(concurrency, Config) of
                           NPool0 when is_integer(NPool0) ->
                               MaxConn0 = erlang:max(10, trunc(MaxCount / NPool0)),
                               {NPool0, MaxConn0};
                           true ->
                               %% if concurrency is set to true then we
                               %% launch, then we launch N pools where 2 * N +
                               %% 2 is the number of threads with a min of 1.
                               %% The number of connections is then equally
                               %% shared between them.
                               N = trunc((erlang:system_info(thread_pool_size) - 1) / 2),
                               NPool0 = erlang:max(1, N),
                               MaxConn0 = erlang:max(10, trunc(MaxCount / NPool0)),
                               {NPool0, MaxConn0};
                           _ ->
                               {1, MaxCount}
                       end,
    HConfig =  [{max_connections, MaxConn}],
    PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
    %% start pools depending on the concurrency
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
    Proc = pooler:take_member(PoolName),
    try
        req(Proc, {request, Method, URL, Headers, Body, Options})
    after
        pooler:return_member(PoolName, Proc, ok)
    end.

-spec async_request(atom(), term(), binary()|list(), list(), term(),
                    list()) -> ok.
async_request(PoolName, Method, URL, Headers, Body, Options) ->
    async_request(PoolName, nil, Method, URL, Headers, Body, Options).

-spec async_request(atom(), term(), term(), binary()|list(), list(), term(),
                    list()) -> ok.
async_request(PoolName, To, Method, URL, Headers, Body, Options) ->
    Proc = pooler:take_member(PoolName),
    cast_req(Proc, To, {request, Method, URL, Headers, Body, Options}),
    ok.

req(Proc, R) ->
    Ref = erlang:monitor(process, Proc),
    Proc ! ?HCALL(self(), R),
    receive
        {'DOWN', Ref, process, Proc, _Info} ->
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
            error_logger:error("** hackney_pooler ~p: unexpected error"
                                "(ignored): ~w~n", [PoolName,
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
