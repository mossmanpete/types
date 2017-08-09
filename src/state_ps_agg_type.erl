%%
%% Copyright (c) 2015-2017 Christopher Meiklejohn.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc @todo

-module(state_ps_agg_type).

-author("Junghun Yoo <junghun.yoo@cs.ox.ac.uk>").

-export([
    mutate/3,
    merge/3,
    is_inflation/2,
    is_strict_inflation/2]).
-export([
    is_partially_ordered/2]).
-export([
    get_events_from_provenance/1,
    is_bottom_provenance/1,
    prune_provenance/2,
    plus_provenance/2,
    cross_provenance/2,
    new_subset_events/0,
    join_subset_events/4,
    new_all_events/0,
    join_all_events/2,
    add_event_to_events/2]).

-export_type([
    crdt/0,
    format/0]).
-export_type([
    state_ps_agg_type/0,
    state_ps_agg_event_type/0,
    state_ps_agg_event_info/0,
    state_ps_agg_event_id/0,
    state_ps_agg_event/0,
    state_ps_agg_dot/0,
    state_ps_agg_provenance/0,
    state_ps_agg_provenance_tensor/0,
    state_ps_agg_provenance_tensor_dict/0,
    state_ps_agg_provenance_store/0,
    state_ps_agg_subset_events/0,
    state_ps_agg_all_events/0,
    state_ps_agg_payload/0]).

%% Define some initial types.
-type crdt() :: {state_ps_agg_type(), type:payload()}.
%% Supported serialization formats.
-type format() :: erlang.
%% A list of types with the provenance semiring for aggregate queries.
-type state_ps_agg_type() ::
    state_ps_agg_aworset_naive |
    state_ps_agg_gcounter_naive |
    state_ps_agg_lwwregister_naive |
    state_ps_agg_size_t_naive.
%% A list of types of events.
-type state_ps_agg_event_type() ::
    state_ps_agg_event_bottom |
    state_ps_agg_event_partial_order_independent |
    state_ps_agg_event_partial_order_downward_closed |
    state_ps_agg_event_total_order.
%% The contents of an event.
-type state_ps_agg_event_info() :: term().
%% An identification for each object (must be unique).
-type state_ps_agg_object_id() :: binary().
%% An identification for each replica (must be comparable/can be ordered).
-type state_ps_agg_replica_id() :: term().
-type state_ps_agg_event_id() ::
    {state_ps_agg_object_id(), state_ps_agg_replica_id()}.
%% An event: this will be generated on related update operations.
%%     Even though all events use the same representation, how they can be
%%     ordered can be different based on the types of events.
-type state_ps_agg_event() ::
    {state_ps_agg_event_type(), state_ps_agg_event_info()}.
%% A dot: a single reason to exist.
%%     Generally a dot contains a single event, but it could have multiple
%%     events after binary operations (such as product() in set-related
%%     operations).
-type state_ps_agg_dot() :: ordsets:ordset(state_ps_agg_event()).
%% A provenance: a set of dots or a dictionary of provenance tensors.
-type state_ps_agg_provenance() ::
    {dots, ordsets:ordset(state_ps_agg_dot())} |
    {tensors, state_ps_agg_provenance_tensor_dict()}.
%% A provenance tensor: a pair of term and its provenance.
-type state_ps_agg_provenance_tensor() :: {term(), state_ps_agg_provenance()}.
-type state_ps_agg_provenance_tensor_dict() ::
    orddict:orddict(term(), state_ps_agg_provenance()).
%% A function from the set of elements to the list of its provenance tensors.
-type state_ps_agg_provenance_store() :: term().
%% A set of survived events.
-type state_ps_agg_subset_events() :: ordsets:ordset(state_ps_agg_event()).
%% A set of the entire events.
-type state_ps_agg_all_events() :: ordsets:ordset(state_ps_agg_event()).
-type state_ps_agg_payload() ::
    {state_ps_agg_provenance_store(),
        state_ps_agg_subset_events(),
        state_ps_agg_all_events()}.

%% Perform a delta mutation.
-callback delta_mutate(type:operation(), type:id(), crdt()) ->
    {ok, crdt()} | {error, type:error()}.
%% Merge two replicas.
%% If we merge two CRDTs, the result is a CRDT.
%% If we merge a delta and a CRDT, the result is a CRDT.
%% If we merge two deltas, the result is a delta (delta group).
-callback merge(crdt(), crdt()) -> crdt().
%% Inflation testing.
-callback is_inflation(crdt(), crdt()) -> boolean().
-callback is_strict_inflation(crdt(), crdt()) -> boolean().
%% @todo These should be moved to type.erl
%% Encode and Decode.
-callback encode(format(), crdt()) -> binary().
-callback decode(format(), binary()) -> crdt().
%% @doc Calculate the next event from the AllEvents.
-callback get_next_event(state_ps_agg_event_id(), state_ps_agg_payload()) ->
    state_ps_agg_event().

%% @doc Generic Mutate.
-spec mutate(type:operation(), type:id(), crdt()) ->
    {ok, crdt()} | {error, type:error()}.
mutate(Op, Actor, {Type, _}=CRDT) ->
    case Type:delta_mutate(Op, Actor, CRDT) of
        {ok, {Type, Delta}} ->
            {ok, Type:merge({Type, Delta}, CRDT)};
        Error ->
            Error
    end.

%% @doc Generic Merge.
-spec merge(crdt(), crdt(), function()) -> crdt().
merge({Type, CRDT1}, {Type, CRDT2}, MergeFun) ->
    MergeFun({Type, CRDT1}, {Type, CRDT2}).

%% @doc Generic check for inflation.
-spec is_inflation(crdt(), crdt()) -> boolean().
is_inflation({Type, _}=CRDT1, {Type, _}=CRDT2) ->
    Type:equal(Type:merge(CRDT1, CRDT2), CRDT2).

%% @doc Generic check for strict inflation.
%%     We have a strict inflation if:
%%         - we have an inflation
%%         - we have different CRDTs
-spec is_strict_inflation(crdt(), crdt()) -> boolean().
is_strict_inflation({Type, _}=CRDT1, {Type, _}=CRDT2) ->
    Type:is_inflation(CRDT1, CRDT2) andalso
        not Type:equal(CRDT1, CRDT2).

%% @doc @todo
-spec is_partially_ordered(state_ps_agg_event(), state_ps_agg_event()) ->
    boolean().
is_partially_ordered({state_ps_agg_event_bottom, _}=_EventL, _EventR) ->
    true;
is_partially_ordered(
    {state_ps_agg_event_partial_order_independent, _}=EventL,
    {state_ps_agg_event_partial_order_independent, _}=EventR) ->
    EventL == EventR;
is_partially_ordered(
    {state_ps_agg_event_partial_order_downward_closed,
        {{_ObjectIdL, _ReplicaIdL}=EventIdL, EventCounterL}}=EventL,
    {state_ps_agg_event_partial_order_downward_closed,
        {{_ObjectIdR, _ReplicaIdR}=EventIdR, EventCounterR}}=EventR) ->
    EventL == EventR orelse
        (EventIdL == EventIdR andalso EventCounterL =< EventCounterR);
is_partially_ordered(
    {state_ps_agg_event_total_order, {{ObjectId, ReplicaIdL}, CounterL}}=EventL,
    {state_ps_agg_event_total_order, {{ObjectId, ReplicaIdR}, CounterR}}=EventR) ->
    EventL == EventR orelse
        CounterL < CounterR orelse
        (CounterL == CounterR andalso ReplicaIdL < ReplicaIdR);
is_partially_ordered(_EventL, _EventR) ->
    false.

%% @doc @todo
-spec events_union(
    state_ps_agg_subset_events() | state_ps_agg_all_events(),
    state_ps_agg_subset_events() | state_ps_agg_all_events()) ->
    state_ps_agg_subset_events() | state_ps_agg_all_events().
events_union(EventsL, EventsR) ->
    ordsets:union(EventsL, EventsR).

%% @doc @todo
-spec events_intersection(
    state_ps_agg_subset_events() | state_ps_agg_all_events(),
    state_ps_agg_subset_events() | state_ps_agg_all_events()) ->
    state_ps_agg_subset_events() | state_ps_agg_all_events().
events_intersection(EventsL, EventsR) ->
    ordsets:intersection(EventsL, EventsR).

%% @doc @todo
-spec events_minus(
    state_ps_agg_subset_events() | state_ps_agg_all_events(),
    state_ps_agg_subset_events() | state_ps_agg_all_events()) ->
    state_ps_agg_subset_events() | state_ps_agg_all_events().
events_minus(EventsL, EventsR) ->
    ordsets:fold(
        fun(CurEvent, AccMaxEvents) ->
            FoundDominant =
                ordsets:fold(
                    fun(OtherEvent, AccFoundDominant) ->
                        AccFoundDominant orelse
                            is_partially_ordered(CurEvent, OtherEvent)
                    end,
                    false,
                    EventsR),
            case FoundDominant of
                false ->
                    ordsets:add_element(CurEvent, AccMaxEvents);
                true ->
                    AccMaxEvents
            end
        end,
        ordsets:new(),
        EventsL).

%% @doc @todo
-spec events_max(state_ps_agg_subset_events() | state_ps_agg_all_events()) ->
    state_ps_agg_subset_events() | state_ps_agg_all_events().
events_max(Events) ->
    ordsets:fold(
        fun(CurEvent, AccMaxEvents) ->
            FoundDominant =
                ordsets:fold(
                    fun(OtherEvent, AccFoundDominant) ->
                        AccFoundDominant orelse
                            (CurEvent /= OtherEvent andalso
                                is_partially_ordered(CurEvent, OtherEvent))
                    end,
                    false,
                    Events),
            case FoundDominant of
                false ->
                    ordsets:add_element(CurEvent, AccMaxEvents);
                true ->
                    AccMaxEvents
            end
        end,
        ordsets:new(),
        Events).

%% @doc Return all events in a provenance.
-spec get_events_from_provenance(state_ps_agg_provenance()) ->
    ordsets:ordset(state_ps_agg_event()).
get_events_from_provenance({dots, Dots}) ->
    ordsets:fold(
        fun(Dot, AccEvents) ->
            ordsets:union(AccEvents, Dot)
        end,
        ordsets:new(),
        Dots);
get_events_from_provenance({tensors, TensorDict}) ->
    orddict:fold(
        fun(_AggElem, Provenance, AccEvents) ->
            ordsets:union(AccEvents, get_events_from_provenance(Provenance))
        end,
        ordsets:new(),
        TensorDict).

%% @doc @todo
-spec is_bottom_provenance(state_ps_agg_provenance()) -> boolean().
is_bottom_provenance({dots, []}) ->
    true;
is_bottom_provenance({dots, _Dots}) ->
    false;
is_bottom_provenance({tensors, []}) ->
    true;
is_bottom_provenance({tensors, _TensorDict}) ->
    false.

%% @doc @todo
-spec prune_provenance(
    state_ps_agg_provenance(), ordsets:ordset(state_ps_agg_event())) ->
    state_ps_agg_provenance().
prune_provenance({dots, Dots}, Events) ->
    NewDots =
        ordsets:fold(
            fun(Dot, AccNewDots) ->
                case ordsets:is_subset(Dot, Events) of
                    true ->
                        ordsets:add_element(
                            Dot, AccNewDots);
                    false ->
                        AccNewDots
                end
            end,
            ordsets:new(),
            Dots),
    {dots, NewDots};
prune_provenance({tensors, TensorDict}, Events) ->
    NewTensorDict =
        orddict:fold(
            fun(AggElem, Provenance, AccNewProvenanceTensor) ->
                NewProvenance = prune_provenance(Provenance, Events),
                case is_bottom_provenance(NewProvenance) of
                    true ->
                        AccNewProvenanceTensor;
                    false ->
                        orddict:store(
                            AggElem,
                            NewProvenance,
                            AccNewProvenanceTensor)
                end
            end,
            orddict:new(),
            TensorDict),
    {tensors, NewTensorDict}.

%% @doc Calculate the plus operation of two provenances.
-spec plus_provenance(state_ps_agg_provenance(), state_ps_agg_provenance()) ->
    state_ps_agg_provenance().
plus_provenance({dots, DotsL}, {dots, DotsR}) ->
    {dots, plus_dots(DotsL, DotsR)};
plus_provenance({dots, DotsL}, {tensors, TensorDictR}) ->
    NewTensorDict =
        orddict:store(undefined, {dots, DotsL}, orddict:new()),
    plus_provenance({tensors, NewTensorDict}, {tensors, TensorDictR});
plus_provenance({tensors, TensorDictL}, {dots, DotsR}) ->
    NewTensorDict =
        orddict:store(undefined, {dots, DotsR}, orddict:new()),
    plus_provenance({tensors, TensorDictL}, {tensors, NewTensorDict});
plus_provenance({tensors, TensorDictL}, {tensors, TensorDictR}) ->
    NewTensorDict =
        orddict:merge(
            fun(_AggElem, ProvenanceL, ProvenanceR) ->
                plus_provenance(ProvenanceL, ProvenanceR)
            end,
            TensorDictL,
            TensorDictR),
    {tensors, NewTensorDict}.

%% @private
plus_dots(DotsL, DotsR) ->
    ordsets:union(DotsL, DotsR).

%% @doc Calculate the cross operation of two provenance tensors.
-spec cross_provenance(state_ps_agg_provenance(), state_ps_agg_provenance()) ->
    state_ps_agg_provenance().
cross_provenance({dots, DotsL}, {dots, DotsR}) ->
    {dots, cross_dots(DotsL, DotsR)};
cross_provenance({dots, DotsL}, {tensors, TensorDictR}) ->
    NewTensorDict =
        orddict:store(undefined, {dots, DotsL}, orddict:new()),
    cross_provenance({tensors, NewTensorDict}, {tensors, TensorDictR});
cross_provenance({tensors, TensorDictL}, {dots, DotsR}) ->
    NewTensorDict =
        orddict:store(undefined, {dots, DotsR}, orddict:new()),
    cross_provenance({tensors, TensorDictL}, {tensors, NewTensorDict});
cross_provenance({tensors, TensorDictL}, {tensors, TensorDictR}) ->
    NewTensorDict =
        orddict:fold(
            fun(AggElemL, ProvenanceL, AccCrossProvenance0) ->
                orddict:fold(
                    fun(AggElemR, ProvenanceR, AccCrossProvenance1) ->
                        CrossAggElem = cross_agg_elem(AggElemL, AggElemR),
                        CrossProvenance =
                            cross_provenance(ProvenanceL, ProvenanceR),
                        orddict:store(
                            CrossAggElem,
                            CrossProvenance,
                            AccCrossProvenance1)
                    end,
                    AccCrossProvenance0,
                    TensorDictR)
            end,
            orddict:new(),
            TensorDictL),
    {tensors, NewTensorDict}.

%% @private
cross_agg_elem(undefined, AggElemR) ->
    AggElemR;
cross_agg_elem(AggElemL, undefined) ->
    AggElemL;
cross_agg_elem(AggElemL, AggElemR) ->
    {AggElemL, AggElemR}.

%% @private
cross_dots(DotsL, DotsR) ->
    ordsets:fold(
        fun(DotL, AccCrossProvenance0) ->
            ordsets:fold(
                fun(DotR, AccCrossProvenance1) ->
                    CrossDot = cross_dot(DotL, DotR),
                    ordsets:add_element(CrossDot, AccCrossProvenance1)
                end,
                AccCrossProvenance0,
                DotsR)
        end,
        ordsets:new(),
        DotsL).

%% @private
cross_dot(DotL, DotR) ->
    ordsets:union(DotL, DotR).

%% @doc @todo
-spec new_subset_events() -> state_ps_agg_subset_events().
new_subset_events() ->
    ordsets:new().

%% @doc @todo
-spec join_subset_events(
    state_ps_agg_subset_events(), state_ps_agg_all_events(),
    state_ps_agg_subset_events(), state_ps_agg_all_events()) ->
    state_ps_agg_subset_events().
join_subset_events(SubsetEventsL, AllEventsL, SubsetEventsR, AllEventsR) ->
    events_union(
        events_intersection(SubsetEventsL, SubsetEventsR),
        events_union(
            events_minus(SubsetEventsL, AllEventsR),
            events_minus(SubsetEventsR, AllEventsL))).

%% @doc @todo
-spec new_all_events() -> state_ps_agg_all_events().
new_all_events() ->
    ordsets:new().

%% @doc @todo
-spec join_all_events(state_ps_agg_all_events(), state_ps_agg_all_events()) ->
    state_ps_agg_all_events().
join_all_events(AllEventsL, AllEventsR) ->
    events_max(events_union(AllEventsL, AllEventsR)).

%% @doc @todo
-spec add_event_to_events(
    ordsets:ordset(state_ps_agg_event()),
    state_ps_agg_subset_events() | state_ps_agg_all_events()) ->
    state_ps_agg_subset_events() | state_ps_agg_all_events().
add_event_to_events(Events, EventSet) ->
    ordsets:union(Events, EventSet).