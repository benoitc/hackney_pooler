-module(hackney_pooler_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    %% init pools
    init_pools(),
    {ok, Pid}.


%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.



init_pools() ->
    case application:get_env(hackney_pooler, pools) of
        undefined -> ok;
        Pools ->
            lists:foreach(fun({PoolName, Conf}) ->
                                  Conf1 = case Conf of
                                              default -> default_conf();
                                              Conf -> Conf
                                          end,
                                  hackney_pooler:new_pool(PoolName, Conf1)
                          end, Pools)
    end.


default_conf() ->
    case application:get_env(hackney_pooler, default_conf) of
        undefined -> [];
        Default -> Default
    end.
