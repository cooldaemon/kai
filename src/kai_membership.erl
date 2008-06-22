% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(kai_membership).
-behaviour(gen_fsm).

-export([start_link/0]).
-export([init/1, ready/2, handle_event/3, handle_sync_event/4, handle_info/3,
	 terminate/3, code_change/4]).
-export([stop/0, check_node/1]).

-include("kai.hrl").

-define(SERVER, ?MODULE).
-define(TIMEOUT, 3000).
-define(TIMER, 1000).

start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], _Opts = []).
	
init(_Args) ->
    {ok, ready, [], ?TIMER}.

terminate(normal, _StateName, _StateData) ->
    ok.

ping_nodes([], AvailableNodes, DownNodes) ->
    {AvailableNodes, DownNodes};
ping_nodes([Node|Nodes], AvailableNodes, DownNodes) ->
    case kai_api:node_info(Node) of
	{node_info, Node2, Info} ->
	    ping_nodes(Nodes, [{Node2, Info}|AvailableNodes], DownNodes);
	{error, _Reason} ->
	    ping_nodes(Nodes, AvailableNodes, [Node|DownNodes])
    end.

retrieve_node_list(Node) ->
    case kai_api:node_list(Node) of
	{node_list, RemoteNodeList} ->
	    {node_list, LocalNodeList} = kai_hash:node_list(),
	    NewNodes = RemoteNodeList -- LocalNodeList,
	    OldNodes = LocalNodeList -- RemoteNodeList,
	    Nodes = NewNodes ++ OldNodes,
	    LocalNode = kai_config:get(node),
	    ping_nodes(Nodes -- [LocalNode], [], []);
	{error, _Reason} ->
	    {[], [Node]}
    end.

sync_buckets([], _LocalNode) ->
    ok;
sync_buckets([{Bucket, NewNodes, OldNodes}|ReplacedBuckets], LocalNode) ->
    case lists:member(LocalNode, NewNodes) of
	true -> kai_sync:update_bucket(Bucket);
	_ -> nop
    end,
    case lists:member(LocalNode, OldNodes) of
	true -> kai_sync:delete_bucket(Bucket);
	_ -> nop
    end,
    sync_buckets(ReplacedBuckets, LocalNode).

sync_buckets(ReplacedBuckets) ->
    LocalNode = kai_config:get(node),
    sync_buckets(ReplacedBuckets, LocalNode).

do_check_node({Address, Port}) ->
    {AvailableNodes, DownNodes} = retrieve_node_list({Address, Port}),
    {replaced_buckets, ReplacedBuckets} =
	kai_hash:update_nodes(AvailableNodes, DownNodes),
    sync_buckets(ReplacedBuckets).

ready({check_node, Node}, State) ->
    do_check_node(Node),
    {next_state, ready, State, ?TIMER};
ready(timeout, State) ->
    case kai_hash:choose_node_randomly() of
	{node, Node} -> do_check_node(Node);
	_ -> nop
    end,
    {next_state, ready, State, ?TIMER}.

handle_event(stop, _StateName, StateData) ->
    {stop, normal, StateData}.
handle_sync_event(_Event, _From, _StateName, StateData) ->
    {next_state, ready, StateData, 3000}.
handle_info(_Info, _StateName, StateData) ->
    {next_state, ready, StateData, 3000}.
code_change(_OldVsn, _StateName, StateData, _Extra) ->
    {ok, ready, StateData}.

stop() ->
    gen_fsm:send_all_state_event(?SERVER, stop).
check_node(Node) ->
    gen_fsm:send_event(?SERVER, {check_node, Node}).