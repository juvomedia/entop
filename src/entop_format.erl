%%==============================================================================
%% Copyright 2010 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================
-module(entop_format).

-author('mazen.harake@erlang-solutions.com').

-include_lib("cecho/include/cecho.hrl").

%% Module API
-export([init/1, header/2, row/2]).

%% Records
-record(state, { node = undefined, cache = [], cycle = 0, reductions = undefined }).

%% Defines
-define(KIB,(1024)).
-define(MIB,(?KIB*1024)).
-define(GIB,(?MIB*1024)).
-define(SECONDS_PER_MIN, 60).
-define(SECONDS_PER_HOUR, (?SECONDS_PER_MIN*60)).
-define(SECONDS_PER_DAY, (?SECONDS_PER_HOUR*24)).
-define(R(V,N), string:right(integer_to_list(V),N,$0)).

%% =============================================================================
%% Module API
%% =============================================================================
init(Node) ->
    Columns = [{"Pid", 10, [{align, right}]},
	       {"Registered Name", 20, []},
	       {"Current Function", 20, []},
	       {"Reds", 8, [{align, right}]},
	       {"Memory", 8, [{align, right}]},
	       {"MQueue", 6, [{align, right}]}],
    {ok, {Columns, 4}, #state{ node = Node, cycle = 0, reductions = gb_trees:empty () }}.

%% Header Callback
header(SystemInfo, State) ->
    Uptime = millis2uptimestr(element(1, proplists:get_value(uptime, SystemInfo, 0))),
    LocalTime = local2str(element(2, proplists:get_value(local_time, SystemInfo))),
    PingTime = element(1,timer:tc(net_adm, ping, [State#state.node])) div 1000,
    Row1 = io_lib:format("Time: local time ~s, up for ~s, ~pms latency, ",
			 [LocalTime, Uptime, PingTime]),

    PTotal = proplists:get_value(process_count, SystemInfo),
    RQueue = proplists:get_value(run_queue, SystemInfo),
    RedTotal = element(2,proplists:get_value(reduction_count, SystemInfo)),
    PMemUsed = proplists:get_value(process_memory_used, SystemInfo),
    PMemTotal = proplists:get_value(process_memory_total, SystemInfo),
    Row2 = io_lib:format("Processes: total ~p (RQ ~p) at ~p RpI using ~s (~s allocated)",
			 [PTotal, RQueue, RedTotal, mem2str(PMemUsed), mem2str(PMemTotal)]),

    MemInfo = proplists:get_value(memory, SystemInfo),
    SystemMem = mem2str(proplists:get_value(system, MemInfo)),
    AtomMem = mem2str(proplists:get_value(atom, MemInfo)),
    AtomUsedMem = mem2str(proplists:get_value(atom_used, MemInfo)),
    BinMem = mem2str(proplists:get_value(binary, MemInfo)),
    CodeMem = mem2str(proplists:get_value(code, MemInfo)),
    EtsMem = mem2str(proplists:get_value(ets, MemInfo)),
    Row3 = io_lib:format("Memory: Sys ~s, Atom ~s/~s, Bin ~s, Code ~s, Ets ~s",
			 [SystemMem, AtomUsedMem, AtomMem, BinMem, CodeMem, EtsMem]),
    Row4 = "",
    NewState = begin_cycle (State),
    {ok, [ lists:flatten(Row) || Row <- [Row1, Row2, Row3, Row4] ], NewState}.

%% Column Specific Callbacks
row([{pid,_}|undefined], State) ->
    {ok, skip, State};
row(ProcessInfo, State) ->
    Pid = proplists:get_value(pid, ProcessInfo),
    RegName = case proplists:get_value(registered_name, ProcessInfo) of
		  [] ->
		      "-";
		  Name ->
		      atom_to_list(Name)
	      end,
    CurFunc =
      case proplists:get_value (current_function, ProcessInfo) of
	{Module, Function, _Arity} ->
	  atom_to_list (Module) ++ ":" ++ atom_to_list (Function);
	_ ->
	  "-"
      end,
    Reductions = proplists:get_value(reductions, ProcessInfo, 0),
    {DeltaReductions, NewState} = delta_reductions (Pid, Reductions, State),
    Memory = proplists:get_value(memory, ProcessInfo, 0),
    MQueue = proplists:get_value(message_queue_len, ProcessInfo, 0),
    {ok, {Pid, RegName, CurFunc, DeltaReductions, Memory, MQueue}, NewState}.

mem2str(Mem) ->
    if Mem > ?GIB -> io_lib:format("~.1fm",[Mem/?MIB]);
       Mem > ?KIB -> io_lib:format("~.1fk",[Mem/?KIB]);
       Mem >= 0 -> io_lib:format("~.1fb",[Mem/1.0])
    end.

millis2uptimestr(Millis) ->
    SecTime = Millis div 1000,
    Days = ?R(SecTime div ?SECONDS_PER_DAY,3),
    Hours = ?R((SecTime rem ?SECONDS_PER_DAY) div ?SECONDS_PER_HOUR,2),
    Minutes = ?R(((SecTime rem ?SECONDS_PER_DAY) rem ?SECONDS_PER_HOUR) div ?SECONDS_PER_MIN, 2),
    Seconds = ?R(((SecTime rem ?SECONDS_PER_DAY) rem ?SECONDS_PER_HOUR) rem ?SECONDS_PER_MIN, 2),
    io_lib:format("~s:~s:~s:~s",[Days,Hours,Minutes,Seconds]).

local2str({Hours,Minutes,Seconds}) ->
    io_lib:format("~s:~s:~s",[?R(Hours,2),?R(Minutes,2),?R(Seconds,2)]).

delta_reductions (Pid, Reductions, State) ->
  OldLookup = State#state.reductions,
  OldReductions =
    case gb_trees:lookup (Pid, OldLookup) of
      none            -> 0;
      {value, {R, _}} -> R
    end,
  Cycle = State#state.cycle,
  NewLookup = gb_trees:enter (Pid, {Reductions, Cycle}, OldLookup),
  NewState = State#state{ reductions = NewLookup },
  DeltaReductions = Reductions - OldReductions,
  {DeltaReductions, NewState}.

begin_cycle (State) ->
  OldCycle = State#state.cycle,
  OldLookup = State#state.reductions,
  NewCycle = OldCycle + 1,
  % prune entries for any pids that did not get updated in previous cycle
  NewLookup =
    gb_trees:from_orddict
      ([ Entry
	 || Entry = {_Pid, {_Reds, Cycle}} <- gb_trees:to_list (OldLookup),
	    Cycle =:= OldCycle ]),
  State#state{ cycle = NewCycle, reductions = NewLookup }.

