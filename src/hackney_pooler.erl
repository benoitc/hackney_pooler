-module(hackney_pooler).
-behaviour(gen_server).

-export([new_pool/2, rm_pool/1, pool_stats/1]).
-export([request/3, request/4, request/5, request/6, request/7, request/8,
         async_request/6, async_request/7, async_request/8]).

%% internal methods
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {parent, hpools, name}).


-define(HCALL(Pid, Req), {'$hackney_call', Pid, Req}).
-define(HCAST(Pid, Req), {'$hackney_cast', Pid, Req}).

%% @doc Start a new pool described by the proplist `PoolConfig'. The
%% following keys are required in the proplist:
%%
%% <dl>
%% <dt>`max_connections'</dt>
%% <dd>An integer giving the max number of connections in a pool used in
%% {@link request/7} and {@link async_request/8}.</dd>
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
                                 Name = {PoolName, uniqid()},
                                 %% start Hackney pool
                                 ok = PoolHandler:start_pool(Name, HConfig),
                                 [Name | Acc]
                         end, [], lists:seq(1, NPool)),

    %% start worker pool

    PoolConfig = [{worker, {?MODULE, [HPools, PoolName]}}] ++ Config,
    wpool:start_pool(PoolName, PoolConfig).

%% @doc Terminate the named pool.
rm_pool(Name) ->
    wpool:stop_pool(Name),
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
    [{workers, wpool:stats(Name)},
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
    request(PoolName, Method, URL, Headers, Body, Options,
            wpool:default_strategy()).

request(PoolName, Method, URL, Headers, Body, Options, Strategy) ->
    request(PoolName, Method, URL, Headers, Body, Options, Strategy, 5000).

request(PoolName, Method, URL, Headers, Body, Options, Strategy, Timeout) ->
    wpool:call(PoolName, {request, Method, URL, Headers, Body, Options},
               Strategy, Timeout).



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
    async_request(PoolName, To, Method, URL, Headers, Body, Options,
                  wpool:default_strategy()).


async_request(PoolName, To, Method, URL, Headers, Body, Options, Strategy) ->
    wpool:cast(PoolName, {request, To, Method, URL, Headers, Body, Options},
               Strategy).


init([HPools, Name]) ->
    process_flag(trap_exit, true),
    {ok, #state{hpools=HPools, name=Name}}.


handle_call({request, Method, Url, Headers, Body, Options}, _From, State) ->
     {HPool, HPools2} = choose_pool(State#state.hpools),
     Reply = do_request(HPool, Method, Url, Headers, Body, Options),
     {reply, Reply, State#state{hpools=HPools2}}.

handle_cast({request, To, Method, Url, Headers, Body, Options}, State) ->
    {HPool, HPools2} = choose_pool(State#state.hpools),
    Reply = do_request(HPool, Method, Url, Headers, Body, Options),

    try
        send_async(To, State#state.name, Reply)
    catch
        _:_ ->
            lager:error("** hackney_pooler (async req) ~p: "
                        "unexpected error (ignored): ~w~n",
                        [State#state.name, erlang:get_stacktrace()])
    end,
    {noreply, State#state{hpools=HPools2}}.


handle_info(Message, State) ->
    lager:info("** hackney_pooler: unexpected message"
               "(ignored): ~w~n", [Message]),
    {noreply, State}.

terminate(_Reason, _State) ->
     %% if a request is running, force close
    case erlang:get(req) of
        undefined -> ok;
        Ref ->
            catch hackney:close(Ref),
            ok
    end,
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



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
            MaxCount = proplists:get_value(workers, Options, 100),
            erlang:max(10, trunc(MaxCount / NPool) + 1)
    end;
maxconn(_, _NPool, Options) ->
    proplists:get_value(workers, Options, 100).


do_request(HPool,  Method, Url, Headers, Body, Options) ->
    %% pass the pool to the config.
    Options1 = [{pool, HPool} | Options],
    %% do the request
    case hackney:request(Method, Url, Headers, Body, Options1) of
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
    end.

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
    lager:notice("** ~p hackney_pooler: unexpected async callback"
                 "(ignored): ~w~n", [PoolName, To]),
    ok.

uniqid() ->
    integer_to_list(erlang:phash2(make_ref())).
