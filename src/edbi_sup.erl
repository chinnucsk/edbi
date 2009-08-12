%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc The pool supervisor (EDBI toplevel supervisor)
%% @end
%%%-------------------------------------------------------------------
-module(edbi_sup).

-behaviour(supervisor).

%% API
-export([start_link/1
         ,start_pool/1
        ]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("pool.hrl").

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================
%%--------------------------------------------------------------------
%% @spec start_link(Args::any()) -> {ok,Pid} | ignore | {error,Error}
%% @doc: Starts the supervisor
%% @end
%%--------------------------------------------------------------------
start_link(_) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_pool(#edbi_pool{name=Id} = P) ->
    CSpec = {Id,
             {edbi_pool_sup,start_link, [P]},
             permanent,2000,supervisor,
             [edbi_pool_sup]},
    supervisor:start_child(?SERVER, CSpec).

%%====================================================================
%% Supervisor callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Func: init
%% @spec (Args) -> {ok,  {SupFlags,  [ChildSpec]}} |
%%                 ignore                          |
%%                 {error, Reason}
%% @doc Whenever a supervisor is started using 
%% supervisor:start_link/[2,3], this function is called by the new process 
%% to find out about restart strategy, maximum restart frequency and child 
%% specifications.
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok,{{one_for_one,1,10},[]}}.
