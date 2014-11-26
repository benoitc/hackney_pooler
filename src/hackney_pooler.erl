-module(hackney_pooler).

-export([new_pool/2, rm_pool/1]).
-export([request/3, request/4, request/5, request/6,
         async_request/6, async_request/7]).

%% internal methods
-export([istart_link/2, init/3,
         system_continue/3, system_terminate/4, system_code_change/4]).

-record(state, {parent, hpool, name}).


-define(HCALL(Pid, Req), {'$hackney_call', Pid, Req}).
-define(HCAST(Pid, Req), {'$hackney_cast', Pid, Req}).


new_pool(Name, Config) ->
    %% maybe initiaalise the Hackney connections pool
    HPool = case proplists:get_value(hackney_pool, Config) of
                undefined ->
                    Group = proplists:get_value(group, Config),
                    MaxConn = proplists:get_value(max_count, Config,
                                                  50),
                    PoolName = Group,
                    PoolHandler = hackney_app:get_app_env(pool_handler,
                                                          hackney_pool),
                    %% start Hackney pool
                    HConfig =  [{max_connections, MaxConn}],
                    PoolHandler:start_pool(PoolName, HConfig),
                    PoolName;
                PoolName ->
                    PoolName
            end,

    %% start worker pool
    Config1 = [{name, Name} |Config],
    PoolConfig = Config1 ++ [{start_mfa,
                              {?MODULE, istart_link, [HPool, Name]}}],
    pooler:new_pool(PoolConfig).

rm_pool(Name) ->
    pooler:rm_pool(Name).


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


istart_link(HPool, Name) ->
    {ok, proc_lib:spawn_link(hackney_pooler, init, [self(), HPool, Name])}.


init(Parent, HPool, Name) ->
    process_flag(trap_exit, true),
    pooler_loop(#state{parent=Parent, hpool=HPool, name=Name}).



pooler_loop(#state{parent=Parent, hpool=Hpool, name=PoolName}=State) ->
    receive
        ?HCALL(From, {request, Method, Url, Headers, Body, Options}) ->

            do_request(From, Hpool, Method, Url, Headers, Body, Options),
            pooler_loop(State);
        ?HCAST(To, {request, Method, Url, Headers, Body, Options}) ->
            do_async_request(PoolName, To, Hpool, Method, Url, Headers, Body,
                             Options),
            pooler:return_member(PoolName, self(), ok),
            pooler_loop(State);
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

    case To of
        nil -> ok;
        Pid when is_pid(Pid) -> Pid ! {hpool, {PoolName, Reply}};
        Fun when is_function(Fun) -> catch Fun({PoolName, Reply});
        {Fun, Acc} when is_function(Fun) -> catch Fun({PoolName, Reply}, Acc);
        _ ->
            error_logger:format("** hackney_pooler: unexpected async callback"
                                "(ignored): ~w~n", [To]),
            ok
    end,
    ok.


terminate(_Reason, _State) ->
    %% if a request is running, force close
    case erlang:get(req) of
        undefined -> ok;
        Ref ->
            catch hackney:close(Ref),
            ok
    end.


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
