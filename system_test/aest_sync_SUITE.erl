-module(aest_sync_SUITE).

%=== EXPORTS ===================================================================

% Common Test exports
-export([all/0]).
-export([init_per_testcase/2]).
-export([end_per_testcase/2]).

% Test cases
-export([new_node_joins_network/1,
         docker_keeps_data/1,
         crash_and_continue_sync/1]).

-import(aest_nodes, [
    setup_nodes/2,
    start_node/2,
    stop_node/2, stop_node/3,
    kill_node/2,
    http_get/5,
    request/4,
    wait_for_height/4,
    assert_synchronized/2
]).

%=== INCLUDES ==================================================================

-include_lib("eunit/include/eunit.hrl").

%=== MACROS ====================================================================

-define(MINING_TIMEOUT, 2000).

-define(OLD_NODE1, #{
    name    => old_node1,
    peers   => [old_node2],
    backend => aest_docker,
    % Change to a compatible fixed version when possible
    source  => {pull, "aeternity/epoch:local"}
}).

-define(OLD_NODE2, #{
    name    => old_node2,
    peers   => [old_node1],
    backend => aest_docker,
    % Change to a compatible fixed version when possible
    source  => {pull, "aeternity/epoch:local"}
}).

-define(NEW_NODE1, #{
    name    => new_node1,
    peers   => [old_node1],
    backend => aest_docker,
    source  => {pull, "aeternity/epoch:local"}
}).

-define(STANDALONE_NODE, #{
    name    => standalone_node,
    peers   => [],
    backend => aest_docker,
    source  => {pull, "aeternity/epoch:local"}
}).

%=== COMMON TEST FUNCTIONS =====================================================

all() -> [
    new_node_joins_network
    , docker_keeps_data
    , crash_and_continue_sync
].

init_per_testcase(_TC, Config) ->
    %% Some parameters depend on the speed and capacity of the docker containers:
    aest_nodes:ct_setup([ {blocks_per_second, 3},
                          {node_startup_time, 5000}, %% Time it takes to get the node to respond to http
                          {node_stop_time, 20000}    %% Time it takes to get the node to stop cleanly
                          | Config]).

end_per_testcase(_TC, Config) ->
    aest_nodes:ct_cleanup(Config).

%=== TEST CASES ================================================================

%% A few tests that verify that our assumptions are right for docker timings and
%% API.

%% A node with a newer version of the code can join and synchronize
%% to a cluster of older nodes.
new_node_joins_network(Cfg) ->
    Length = 20,
    NodeStartupTime = proplists:get_value(node_startup_time, Cfg),

    setup_nodes([?OLD_NODE1, ?OLD_NODE2, ?NEW_NODE1], Cfg),

    %% Starts a chain with two nodes
    start_node(old_node1, Cfg),
    start_node(old_node2, Cfg),
    wait_for_height(0, [old_node1, old_node2], NodeStartupTime, Cfg),

    %% Mines for 20 blocks and calculate the average mining time
    StartTime = os:timestamp(),
    wait_for_height(Length, [old_node1, old_node2], Length * ?MINING_TIMEOUT, Cfg),
    EndTime = os:timestamp(),
    %% Average mining time per block plus 50% extra
    MiningTime = round(timer:now_diff(EndTime, StartTime) * 1.5)
                 div (1000 * Length),

    Top1 = request(old_node1, [v2, 'top'], #{}, Cfg),
    ct:log("Node 1 top: ~p~n", [Top1]),
    Height1 = request(old_node1, [v2, 'block-by-height'], #{height => Length}, Cfg),
    ct:log("Node 1 at height ~p: ~p~n", [Length, Height1]),
    Height2 = request(old_node2, [v2, 'block-by-height'], #{height => Length}, Cfg),
    ct:log("Node 2 at height ~p: ~p~n", [Length, Height2]),

    %% Checks node 1 and 2 are synchronized
    ?assertEqual(Height1, Height2),

    %% Starts a third node and check it synchronize with the first two
    start_node(new_node1, Cfg),
    wait_for_height(0, [new_node1], NodeStartupTime, Cfg),
    ct:log("Node 3 ready to go"),

    %% Waits enough for node 3 to sync but not for it to build a new chain
    wait_for_height(Length, [new_node1], MiningTime * 3, Cfg),
    ct:log("Node 3 on same height"),
    Height3 = request(new_node1, [v2, 'block-by-height'], #{height => Length}, Cfg),
    ct:log("Node 3 at height ~p: ~p~n", [Length, Height3]),

    %% Checks node 3 is synchronized with nodes 1 and 2
    ?assertEqual(Height1, Height3),
    ok.

%% When we stop and restart a node we will be able to read the blocks
%% that we had in the chain before stopping: data is persistent.
docker_keeps_data(Cfg) ->
    Length = 20,
    NodeStartupTime = proplists:get_value(node_startup_time, Cfg),

    setup_nodes([?STANDALONE_NODE], Cfg),

    start_node(standalone_node, Cfg),
    wait_for_height(0, [standalone_node], NodeStartupTime, Cfg),

    %% Mines for 20 blocks and calculate the average mining time
    StartTime = os:timestamp(),
    wait_for_height(Length, [standalone_node], Length * ?MINING_TIMEOUT, Cfg),
    EndTime = os:timestamp(),
    %% Average mining time per block plus 50% extra
    MiningTime = round(timer:now_diff(EndTime, StartTime) * 1.5)
                 div (1000 * Length),

    %% Get all blocks before stopping
    A = [get_block(standalone_node, H, Cfg) || H <- lists:seq(1, Length)],

    stop_node(standalone_node, infinity, Cfg), %% Is this triggering PT-155851463 ?
    start_node(standalone_node, Cfg),
    wait_for_height(0, [standalone_node], NodeStartupTime, Cfg),

    ct:log("Node restarted and ready to go"),

    %% Give it time to read from disk, but not enough to build a new chain of same length
    timer:sleep(MiningTime * 8),

    %% Get all blocks after restarting
    B = [get_block(standalone_node, H, Cfg) || H <- lists:seq(1, Length)],

    %% Checks all the nodes before restarting are still there
    {_, Diff} = lists:foldl(fun({X, Y}, {H, Acc}) ->
        case X =:= Y of
            true -> {H + 1, Acc};
            false ->
                ct:log("Block ~w changed after restart:~n"
                       "BEFORE:~n~p~nAFTER:~n~p~n", [H, X, Y]),
                {H + 1, [H | Acc]}
        end
    end, {1, []}, lists:zip(A, B)),
    ?assertEqual([], Diff),

    %% Mines 10 more blocks
    wait_for_height(Length + 10, [standalone_node], MiningTime * 10, Cfg),

    %% Get all blocks before stopping
    C = [get_block(standalone_node, H, Cfg) || H <- lists:seq(1, Length + 10)],

    stop_node(standalone_node, infinity, Cfg),
    start_node(standalone_node, Cfg),
    wait_for_height(0, [standalone_node], NodeStartupTime, Cfg),


    %% Give it time to read from disk, but not enough to build a new chain of same length
    timer:sleep(MiningTime * 5),

    %% Get all blocks after restarting
    D = [get_block(standalone_node, H, Cfg) || H <- lists:seq(1, Length + 10)],

    %% Checks all the nodes before restarting are still there
    {_, Diff} = lists:foldl(fun({X, Y}, {H, Acc}) ->
        case X =:= Y of
            true -> {H + 1, Acc};
            false ->
                ct:log("Block ~w changed after second restart:~n"
                       "BEFORE:~n~p~nAFTER:~n~p~n", [H, X, Y]),
                {H + 1, [H | Acc]}
        end
    end, {1, []}, lists:zip(C, D)),
    ?assertEqual([], Diff),

    ok.

crash_and_continue_sync(Cfg) ->
    BlocksPerSecond = proplists:get_value(blocks_per_second, Cfg),
    NodeStartupTime = proplists:get_value(node_startup_time, Cfg),
    %% Create a chain long enough to need 10 seconds to fetch it
    Length = BlocksPerSecond * 20,

    setup_nodes([?OLD_NODE1, ?OLD_NODE2], Cfg),

    start_node(old_node1, Cfg),
    wait_for_height(0, [old_node1], NodeStartupTime, Cfg),

    StartTime = os:timestamp(),
    wait_for_height(Length, [old_node1], Length * ?MINING_TIMEOUT, Cfg),
    EndTime = os:timestamp(),
    %% Average mining time per block plus 50% extra
    MiningTime = round(timer:now_diff(EndTime, StartTime) * 1.5)
                 div (1000 * Length),

    B1 = request(old_node1, [v2, 'block-by-height'], #{height => Length}, Cfg),
    ct:log("Node 1 at height ~p: ~p~n", [Length, B1]),

    %% Start fetching the chain
    start_node(old_node2, Cfg),
    wait_for_height(0, [old_node2], NodeStartupTime, Cfg),
    ct:log("Node 2 ready to go"),

    %% we are fetching blocks crash now
    kill_node(old_node1, Cfg),
    Top2 = request(old_node2, [v2, 'top'], #{}, Cfg),
    ct:log("Node 2 top: ~p~n", [Top2]),
    Height = maps:get(height, Top2),
    case Height >= Length of
         true -> {skip, already_synced_when_crashed};
         false ->
            start_node(old_node1, Cfg),
            wait_for_height(Length, [old_node2], (Length - Height) * MiningTime, Cfg),
            B2 = request(old_node2, [v2, 'block-by-height'], #{height => Length}, Cfg),
            ct:log("Node 2 at height ~p: ~p~n", [Length, B2]),
            ?assertEqual(B1, B2)
    end.

%=== INTERNAL FUNCTIONS ========================================================

get_block(NodeName, Height, Cfg) ->
    Query = #{height => Height},
    case http_get(NodeName, ext_http, [v2, 'block-by-height'], Query, Cfg) of
        {ok, 200, Block} -> Block;
        {ok, 404, _} -> undefined
    end.