-module(mongodb).
-export([deser_prop/1,reload/0, print_info/0, start/0, stop/0, init/1, handle_call/3, 
		 handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([connect/0, exec_cursor/2, exec_delete/2, exec_cmd/2, exec_insert/2, exec_find/2, exec_update/2, exec_getmore/2,  
         encoderec/1, encode_findrec/1, encoderec_selector/2, gen_keyname/2, decoderec/2, encode/1, decode/1,
         singleServer/1, singleServer/0, masterSlave/2,masterMaster/2, replicaPairs/2]).
-include_lib("erlmongo.hrl").
% -define(RIN, record_info(fields, enctask)).


% -compile(export_all).
-define(MONGO_PORT, 27017).
-define(RECONNECT_DELAY, 1000).

-define(OP_REPLY, 1).
-define(OP_MSG, 1000).
-define(OP_UPDATE, 2001).
-define(OP_INSERT, 2002).
-define(OP_QUERY, 2004).
-define(OP_GET_MORE, 2005).
-define(OP_DELETE, 2006).
-define(OP_KILL_CURSORS, 2007).


reload() ->
	gen_server:call(?MODULE, {reload_module}).
	% code:purge(?MODULE),
	% code:load_file(?MODULE),
	% spawn(fun() -> register() end).

start() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
	gen_server:call(?MODULE, stop).
	
% register() ->
% 	supervisor:start_child(supervisor, {?MODULE, {?MODULE, start, []}, permanent, 1000, worker, [?MODULE]}).
		
print_info() ->
	gen_server:cast(?MODULE, {print_info}).


% SPEED TEST
% loop(N) ->
% 	io:format("~p~n", [now()]),
% 	t(N, true),
% 	io:format("~p~n", [now()]).

% t(0, _) ->
% 	true;
% t(N, R) ->
% 	% encoderec(#mydoc{name = <<"IZ_RECORDA">>, i = 12}),
% 	% decoderec(#mydoc{}, R),
% 	ensureIndex(#mydoc{}, [{#mydoc.name, -1},{#mydoc.i, 1}]),
% 	t(N-1, R).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%								API
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
connect() ->
	gen_server:cast(?MODULE, {start_connection}).
singleServer() ->
	gen_server:cast(?MODULE, {conninfo, {replicaPairs, {"localhost",?MONGO_PORT}, {"localhost",?MONGO_PORT}}}).
singleServer(Addr) ->
	[Addr,Port] = string:tokens(Addr,":"),
	% gen_server:cast(?MODULE, {conninfo, {single, {Addr,Port}}}).
	gen_server:cast(?MODULE, {conninfo, {replicaPairs, {Addr,Port}, {Addr,Port}}}).
masterSlave(Addr1, Addr2) ->
	[Addr1,Port1] = string:tokens(Addr1,":"),
	[Addr2,Port2] = string:tokens(Addr2,":"),
	gen_server:cast(?MODULE, {conninfo, {masterSlave, {Addr1,Port1}, {Addr2,Port2}}}).
masterMaster(Addr1,Addr2) ->
	[Addr1,Port1] = string:tokens(Addr1,":"),
	[Addr2,Port2] = string:tokens(Addr2,":"),
	gen_server:cast(?MODULE, {conninfo, {masterMaster, {Addr1,Port1}, {Addr2,Port2}}}).
replicaPairs(Addr1,Addr2) ->
	[Addr1,Port1] = string:tokens(Addr1,":"),
	[Addr2,Port2] = string:tokens(Addr2,":"),
	gen_server:cast(?MODULE, {conninfo, {replicaPairs, {Addr1,Port1}, {Addr2,Port2}}}).

exec_cursor(Col, Quer) ->
	case gen_server:call(?MODULE, {getread}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {find, self(), Col, Quer},
			receive
				{query_result, _Src, <<_ReqID:32/little, _RespTo:32/little, 1:32/little, 0:32, 
								 CursorID:64/little, _From:32/little, _NDocs:32/little, Result/binary>>} ->
					% io:format("cursor ~p from ~p ndocs ~p, ressize ~p ~n", [_CursorID, _From, _NDocs, byte_size(Result)]),
					% io:format("~p~n", [Result]),
					case CursorID of
						0 ->
							{done, Result};
						_ ->
							PID = spawn_link(fun() -> cursorcleanup(true) end),
							PID ! {start, CursorID},
							{#cursor{id = CursorID, limit = Quer#search.ndocs, pid = PID}, Result}
					end
				after 1000 ->
					<<>>
			end
	end.
exec_getmore(Col, C) ->
	case gen_server:call(?MODULE, {getread}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {getmore, self(), Col, C},
			receive
				{query_result, _Src, <<_ReqID:32/little, _RespTo:32/little, 1:32/little, 0:32, 
								 CursorID:64/little, _From:32/little, _NDocs:32/little, Result/binary>>} ->
					% io:format("cursor ~p from ~p ndocs ~p, ressize ~p ~n", [_CursorID, _From, _NDocs, byte_size(Result)]),
					% io:format("~p~n", [Result]),
					case CursorID of
						0 ->
							C#cursor.pid ! {stop},
							{done, Result};
						_ ->
							{ok, Result}
					end
				after 1000 ->
					<<>>
			end
	end.
exec_delete(Collection, D) ->
	case gen_server:call(?MODULE, {getwrite}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {delete, Collection, D}
	end,
	ok.
exec_find(Collection, Quer) ->
	case gen_server:call(?MODULE, {getread}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {find, self(), Collection, Quer},
			receive
				{query_result, _Src, <<_ReqID:32/little, _RespTo:32/little, 1:32/little, 0:32, 
								 _CursorID:64/little, _From:32/little, _NDocs:32/little, Result/binary>>} ->
					% io:format("cursor ~p from ~p ndocs ~p, ressize ~p ~n", [_CursorID, _From, _NDocs, byte_size(Result)]),
					% io:format("~p~n", [Result]),
					Result
				after 1000 ->
					<<>>
			end
	end.
exec_insert(Collection, D) ->
	case gen_server:call(?MODULE, {getwrite}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {insert, Collection, D}
	end,
	ok.
exec_update(Collection, D) ->
	case gen_server:call(?MODULE, {getwrite}) of
		undefined ->
			not_connected;
		PID ->
			PID ! {update, Collection, D}
	end,
	ok.
exec_cmd(DB, Cmd) ->
	Quer = #search{ndocs = 1, nskip = 0, criteria = mongodb:encode(Cmd)},
	case exec_find(<<DB/binary, ".$cmd">>, Quer) of
		undefined ->
			not_connected;
		<<>> ->
			[];
		Result ->
			mongodb:decode(Result)
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%								IMPLEMENTATION
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% read = connection used for reading (find) from mongo server
% write = connection used for writing (insert,update) to mongo server
%   single: same as replicaPairs (single server is always master and used for read and write)
%   masterSlave: read = slave, write = master
%   replicaPairs: read = write = master
%   masterMaster: read = master1, write = master2
% timer is reconnect timer if some connection is missing
% indexes is ensureIndex cache (an ets table).
-record(mngd, {read, write, conninfo, indexes, timer}).
-define(R2P(Record), rec2prop(Record, record_info(fields, mngd))).
-define(P2R(Prop), prop2rec(Prop, mngd, #mngd{}, record_info(fields, mngd))).	
	
handle_call({getread}, _, P) ->
	{reply, P#mngd.read, P};
handle_call({getwrite}, _, P) ->
	{reply, P#mngd.write, P};
handle_call(stop, _, P) ->
	{stop, shutdown, stopped, P};
handle_call({reload_module}, _, P) ->
	code:purge(?MODULE),
	code:load_file(?MODULE),
	{reply, ok, ?MODULE:deser_prop(?R2P(P))};
handle_call(_, _, P) ->
	{reply, ok, P}.

deser_prop(P) ->
	?P2R(P).

startcon(undefined, Type, Addr,Port) ->
	PID = spawn_link(fun() -> connection(true) end),
	PID ! {start, self(), Type, Addr, Port};
startcon(PID, _, _, _) ->
	PID.
	
handle_cast({ensure_index, Bin}, P) ->
	case ets:lookup(P#mngd.indexes, Bin) of
		[] ->
			spawn(fun() -> exec_insert(<<"system.indexes">>, #insert{documents = Bin}) end),
			ets:insert(P#mngd.indexes, {Bin});
		_ ->
			true
	end,
	{noreply, P};
handle_cast({clear_indexcache}, P) ->
	ets:delete_all_objects(P#mngd.indexes),
	{noreply, P};
handle_cast({conninfo, Conn}, P) ->
	{noreply, P#mngd{conninfo = Conn}};
handle_cast({start_connection}, #mngd{conninfo = {masterMaster, {A1,P1},{A2,P2}}} = P)  ->
	case true of
		_ when P#mngd.read /= P#mngd.write, P#mngd.read /= undefined, P#mngd.write /= undefined ->
			Timer = ctimer(P#mngd.timer);
		_ when P#mngd.read == P#mngd.write, P#mngd.read /= undefined ->
			startcon(undefined, write, A2,P2),
			Timer = P#mngd.timer;
		_ ->
			startcon(P#mngd.read, read, A1,P1),
			startcon(P#mngd.write, write, A2,P2),
			Timer = P#mngd.timer
			% {noreply, P#mngd{read = startcon(P#mngd.read, A1,P1), write = startcon(P#mngd.write,A2,P2)}}
	end,
	{noreply, P#mngd{timer = Timer}};
handle_cast({start_connection}, #mngd{conninfo = {masterSlave, {A1,P1},{A2,P2}}} = P)  ->
	case true of
		% All ok.
		_ when P#mngd.read /= P#mngd.write, P#mngd.read /= undefined, P#mngd.write /= undefined ->
			Timer = ctimer(P#mngd.timer);
		% Read = write = master, try to connect to slave again
		_ when P#mngd.read == P#mngd.write, P#mngd.read /= undefined ->
			startcon(undefined, read, A2,P2),
			Timer = P#mngd.timer;
		% One or both of the connections is down
		_ ->
			startcon(P#mngd.read, read, A2,P2),
			startcon(P#mngd.write, write, A1,P1),
			Timer = P#mngd.timer
	end,
	{noreply, P#mngd{timer = Timer}};
handle_cast({start_connection}, #mngd{conninfo = {replicaPairs, {A1,P1},{A2,P2}}} = P)  ->
	case true of
		_ when P#mngd.read /= undefined, P#mngd.write == P#mngd.read ->
			{noreply, P#mngd{timer = ctimer(P#mngd.timer)}};
		_ ->
			startcon(undefined, ifmaster, A1,P1),
			startcon(undefined, ifmaster, A2,P2),
			{noreply, P}
	end;
handle_cast({print_info}, P) ->
	io:format("~p~n", [?R2P(P)]),
	{noreply, P};
handle_cast(_, P) ->
	{noreply, P}.

ctimer(undefined) ->
	undefined;
ctimer(T) ->
	timer:cancel(T),
	undefined.

timer(undefined) ->
	{ok, Timer} = timer:send_interval(?RECONNECT_DELAY, {reconnect}),
	Timer;
timer(T) ->
	T.

handle_info({conn_established, read, ConnProc}, P) ->
	{noreply, P#mngd{read = ConnProc}};
handle_info({conn_established, write, ConnProc}, P) ->
	{noreply, P#mngd{write = ConnProc}};
handle_info({reconnect}, P) ->
	handle_cast({start_connection}, P);
handle_info({'EXIT', PID, _Reason}, #mngd{conninfo = {replicaPairs, _, _}} = P) ->
	case true of
		_ when P#mngd.read == PID ->
			{noreply, P#mngd{read = undefined, write = undefined, timer = timer(P#mngd.timer)}};
		_ ->
			{noreply, P}
	end;
handle_info({'EXIT', PID, _Reason}, #mngd{conninfo = {masterSlave, _, _}} = P) ->
	case true of
		_ when P#mngd.read == PID, P#mngd.read /= P#mngd.write ->
			{noreply, P#mngd{read = P#mngd.write, timer = timer(P#mngd.timer)}};
		_ when P#mngd.read == PID ->
			{noreply, P#mngd{read = undefined, write = undefined, timer = timer(P#mngd.timer)}};
		_ when P#mngd.write == PID ->
			{noreply, P#mngd{write = undefined, timer = timer(P#mngd.timer)}};
		_ ->
			{noreply, P}
	end;
handle_info({'EXIT', PID, _Reason}, #mngd{conninfo = {masterMaster, _, _}} = P) ->
	case true of
		_ when P#mngd.read == PID, P#mngd.write == PID ->
			{noreply, P#mngd{read = undefined, write = undefined, timer = timer(P#mngd.timer)}};
		_ when P#mngd.read == PID ->
			{noreply, P#mngd{read = P#mngd.write, timer = timer(P#mngd.timer)}};
		_ when P#mngd.write == PID ->
			{noreply, P#mngd{write = P#mngd.read, timer = timer(P#mngd.timer)}};
		_ ->
			{noreply, P}
	end;
handle_info({query_result, Src, <<_:32/binary, Res/binary>>}, P) ->
	try mongodb:decode(Res) of
		[{<<"ismaster">>, 1}|_] when element(1,P#mngd.conninfo) == replicaPairs, P#mngd.read == undefined ->
			link(Src),
			{noreply, P#mngd{read = Src, write = Src}};
		_ ->
			Src ! {stop},
			{noreply, P}
	catch
		error:_ ->
			Src ! {stop},
			{noreply, P}
	end;
handle_info({query_result, Src, _}, P) ->
	Src ! {stop},
	{noreply, P};
handle_info(_X, P) -> 
	io:format("~p~n", [_X]),
	{noreply, P}.

terminate(_, _) ->
	ok.
code_change(_, P, _) ->
	{ok, P}.
init([]) ->
	% timer:send_interval(1000, {timeout}),
	process_flag(trap_exit, true),
	{ok, #mngd{indexes = ets:new(mongoIndexes, [set, private])}}.
	
% find_master([{A,P}|T]) ->
% 	Q = #search{ndocs = 1, nskip = 0, quer = mongodb:encode([{<<"ismaster">>, 1}])},
% 	
				


-record(ccd, {cursor = 0}).
% Just for cleanup
cursorcleanup(P) ->
	receive
		{stop} ->
			true;
		{cleanup} ->
			case gen_server:call(?MODULE, {get_conn}) of
				false ->
					false;
				PID ->
					PID ! {killcursor, #killc{cur_ids = <<(P#ccd.cursor):64/little>>}},
					true
			end;
		{'EXIT', _PID, _Why} ->
			self() ! {cleanup},
			cursorcleanup(P);
		{start, Cursor} ->
			process_flag(trap_exit, true),
			cursorcleanup(#ccd{cursor = Cursor})
	end.


-record(con, {sock, source, buffer = <<>>, state = free}).
% Waiting for request
connection(true) ->
	connection(#con{});
connection(#con{state = free} = P) ->
	receive
		{find, Source, Collection, Query} ->
			QBin = constr_query(Query, Collection),
			ok = gen_tcp:send(P#con.sock, QBin),
			connection(P#con{state = waiting, source = Source});
		{insert, Collection, Doc} ->
			Bin = constr_insert(Doc, Collection),
			ok = gen_tcp:send(P#con.sock, Bin),
			connection(P);
		{update, Collection, Doc} ->
			Bin = constr_update(Doc, Collection),
			ok = gen_tcp:send(P#con.sock, Bin),
			connection(P);
		{delete, Col, D} ->
			Bin = constr_delete(D, Col),
			ok = gen_tcp:send(P#con.sock, Bin),
			connection(P);
		{getmore, Source, Col, C} ->
			Bin = constr_getmore(C, Col),
			ok = gen_tcp:send(P#con.sock, Bin),
			connection(P#con{state = waiting, source = Source});
		{killcursor, C} ->
			Bin = constr_killcursors(C),
			ok = gen_tcp:send(P#con.sock, Bin),
			connection(P);
		{tcp, _, _Bin} ->
			connection(P);
		{stop} ->
			true;
		{start, Source, Type, IP, Port} ->
			{A1,A2,A3} = now(),
		    random:seed(A1, A2, A3),
			{ok, Sock} = gen_tcp:connect(IP, Port, [binary, {packet, 0}, {active, true}, {keepalive, true}]),
			case Type of
				ifmaster ->
					self() ! {find, Source, <<"admin.$cmd">>, #search{nskip = 0, ndocs = 1, criteria = mongodb:encode([{<<"ismaster">>, 1}])}};
				_ ->
					Source ! {conn_established, Type, self()}
			end,
			connection(#con{sock = Sock});
		{tcp_closed, _} ->
			exit(stop)
	end;
% waiting for response
connection(P) ->
	receive
		{tcp, _, Bin} ->
			<<Size:32/little, Packet/binary>> = <<(P#con.buffer)/binary, Bin/binary>>,
			% io:format("Received size ~p~n", [Size]),
			case Size of
				 _ when Size == byte_size(Packet) + 4 ->
					P#con.source ! {query_result, self(), Packet},
					connection(P#con{state = free, buffer = <<>>});
				_ ->
					connection(P#con{buffer = <<(P#con.buffer)/binary, Bin/binary>>})
			end;
		{stop} ->
			true;
		{tcp_closed, _} ->
			exit(stop)
		after 2000 ->
			exit(stop)
	end.

constr_header(Len, ID, RespTo, OP) ->
	<<(Len+16):32/little, ID:32/little, RespTo:32/little, OP:32/little>>.

constr_update(U, Name) ->
	Update = <<0:32, Name/binary, 0:8, 
	           (U#update.upsert):32/little, (U#update.selector)/binary, (U#update.document)/binary>>,
	Header = constr_header(byte_size(Update), random:uniform(4000000000), 0, ?OP_UPDATE),
	<<Header/binary, Update/binary>>.

constr_insert(U, Name) ->
	Insert = <<0:32, Name/binary, 0:8, (U#insert.documents)/binary>>,
	Header = constr_header(byte_size(Insert), random:uniform(4000000000), 0, ?OP_INSERT),
	<<Header/binary, Insert/binary>>.

constr_query(U, Name) ->
	Query = <<(U#search.opts):32/little, Name/binary, 0:8, (U#search.nskip):32/little, (U#search.ndocs):32/little, 
	  		  (U#search.criteria)/binary, (U#search.field_selector)/binary>>,
	Header = constr_header(byte_size(Query), random:uniform(4000000000), 0, ?OP_QUERY),
	<<Header/binary,Query/binary>>.

constr_getmore(U, Name) ->
	GetMore = <<0:32, Name/binary, 0:8, (U#cursor.limit):32/little, (U#cursor.id):62/little>>,
	Header = constr_header(byte_size(GetMore), random:uniform(4000000000), 0, ?OP_GET_MORE),
	<<Header/binary, GetMore/binary>>.

constr_delete(U, Name) ->
	Delete = <<0:32, Name/binary, 0:8, 0:32, (U#delete.selector)/binary>>,
	Header = constr_header(byte_size(Delete), random:uniform(4000000000), 0, ?OP_DELETE),
	<<Header/binary, Delete/binary>>.
	
constr_killcursors(U) ->
	Kill = <<0:32, (byte_size(U#killc.cur_ids) div 8):32, (U#killc.cur_ids)/binary>>,
	Header = constr_header(byte_size(Kill), random:uniform(4000000000), 0, ?OP_KILL_CURSORS),
	<<Header/binary, Kill/binary>>.




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%						BSON encoding/decoding 
%	most of it taken and modified from the mongo-erlang-driver project by Elias Torres
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

encoderec(Rec) ->
	[_|Fields] = element(element(2, Rec), ?RECTABLE),
	encoderec(<<>>, deep, Rec, Fields, 3, <<>>).
encode_findrec(Rec) ->
	[_|Fields] = element(element(2, Rec), ?RECTABLE),
	encoderec(<<>>, flat, Rec, Fields, 3, <<>>).
	
encoderec(NameRec, Type, Rec, [{FieldName, _RecIndex}|T], N, Bin) ->
	case element(N, Rec) of
		undefined ->
			encoderec(NameRec, Type, Rec, T, N+1, Bin);
		SubRec when Type == flat ->
			[_|SubFields] = element(element(2, SubRec), ?RECTABLE),
			case NameRec of
				<<>> ->
					Dom = atom_to_binary(FieldName, latin1);
				_ ->
					Dom = <<NameRec/binary, ".", (atom_to_binary(FieldName, latin1))/binary>>
			end,
			encoderec(NameRec, Type, Rec, T, N+1, <<Bin/binary, (encoderec(Dom, flat, SubRec, SubFields, 3, <<>>))/binary>>);
		Val ->
			encoderec(NameRec, Type, Rec, T, N+1, <<Bin/binary, (encode_element({atom_to_binary(FieldName, latin1), {bson, encoderec(Val)}}))/binary>>)
	end;
encoderec(NameRec, Type, Rec, [FieldName|T], N, Bin) ->
	case element(N, Rec) of
		undefined ->
			encoderec(NameRec, Type,Rec, T, N+1, Bin);
		Val ->
			case FieldName of
				docid ->
					encoderec(NameRec, Type,Rec, T, N+1, <<Bin/binary, (encode_element({<<"_id">>, Val}))/binary>>);
				_ ->
					case NameRec of
						<<>> ->
							Dom = atom_to_binary(FieldName, latin1);
						_ ->
							Dom = <<NameRec/binary, ".", (atom_to_binary(FieldName, latin1))/binary>>
					end,
					encoderec(NameRec, Type,Rec, T, N+1, <<Bin/binary, (encode_element({Dom, Val}))/binary>>)
			end
	end;
encoderec(<<>>,_,_, [], _, Bin) ->
	<<(byte_size(Bin)+5):32/little, Bin/binary, 0:8>>;
encoderec(_,_,_, [], _, Bin) ->
	% <<(byte_size(Bin)+5):32/little, Bin/binary, 0:8>>.
	Bin.

encoderec_selector(_, undefined) ->
	<<>>;
encoderec_selector(_, <<>>) ->
	<<>>;
encoderec_selector(Rec, SelectorList) ->
	[_|Fields] = element(element(2, Rec), ?RECTABLE),
	encoderec_selector(SelectorList, Fields, 3, <<>>).

% SelectorList is either a list of indexes in the record tuple, or a list of {TupleIndex, TupleVal}. Use the index to get the name
% from the list of names.
encoderec_selector([{FieldIndex, Val}|Fields], [FieldName|FieldNames], FieldIndex, Bin) ->
	case FieldName of
		docid ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({<<"_id">>, Val}))/binary>>);
		{Name, _RecIndex} ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({atom_to_binary(Name,latin1), Val}))/binary>>);
		_ ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({atom_to_binary(FieldName,latin1), Val}))/binary>>)
	end;
encoderec_selector([FieldIndex|Fields], [FieldName|FieldNames], FieldIndex, Bin) ->
	case FieldName of
		docid ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({<<"_id">>, 1}))/binary>>);
		{Name, _RecIndex} ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({atom_to_binary(Name,latin1), 1}))/binary>>);
		_ ->
			encoderec_selector(Fields, FieldNames, FieldIndex+1, <<Bin/binary, (encode_element({atom_to_binary(FieldName,latin1), 1}))/binary>>)
	end;
encoderec_selector(Indexes, [_|Names], Index, Bin) ->
	encoderec_selector(Indexes, Names, Index+1, Bin);
encoderec_selector([], _, _, Bin) ->
	<<(byte_size(Bin)+5):32/little, Bin/binary, 0:8>>.
	
gen_keyname(Rec, Keys) ->
	[_|Fields] = element(element(2, Rec), ?RECTABLE),
	gen_keyname(Keys, Fields, 3, <<>>).

gen_keyname([{KeyIndex, KeyVal}|Keys], [Field|Fields], KeyIndex, Name) ->
	case Field of
		{FieldName, _} ->
			true;
		FieldName ->
			true
	end,
	case is_integer(KeyVal) of
		true ->
			Add = <<(list_to_binary(integer_to_list(KeyVal)))/binary>>;
		false ->
			Add = <<>>
	end,
	gen_keyname(Keys, Fields, KeyIndex+1, <<Name/binary, "_", (atom_to_binary(FieldName, latin1))/binary, "_", Add/binary>>);
gen_keyname([], _, _, <<"_", Name/binary>>) ->
	Name;
gen_keyname(Keys, [_|Fields], KeyIndex, Name) ->
	gen_keyname(Keys, Fields, KeyIndex+1, Name).
	

decoderec(Rec, <<>>) ->
	% Rec;
	erlang:make_tuple(tuple_size(Rec), undefined, [{1, element(1,Rec)}, {2, element(2,Rec)}]);
decoderec(Rec, Bin) ->
	[_|Fields] = element(element(2, Rec), ?RECTABLE),
	decode_records([], Bin, tuple_size(Rec), element(1,Rec), element(2, Rec), Fields).

decode_records(RecList, <<_ObjSize:32/little, Bin/binary>>, TupleSize, Name, TabIndex, Fields) ->
	{FieldList, Remain} = get_fields([], Fields, Bin),
	% io:format("~p~n", [FieldList]),
	NewRec = erlang:make_tuple(TupleSize, undefined, [{1, Name},{2, TabIndex}|FieldList]),
	decode_records([NewRec|RecList], Remain, TupleSize, Name, TabIndex, Fields);
decode_records(R, <<>>, _, _, _, _) ->
	lists:reverse(R).

get_fields(RecVals, Fields, Bin) ->
	case rec_field_list(RecVals, 3, Fields, Bin) of
		{again, SoFar, Rem} ->
			get_fields(SoFar, Fields, Rem);
		Res ->
			Res
	end.

rec_field_list(RecVals, _, _, <<0:8, Rem/binary>>) ->
	{RecVals, Rem};
	% done;
rec_field_list(RecVals, _, [], <<Type:8, Bin/binary>>) ->
	{_Name, ValRem} = decode_cstring(Bin, <<>>),
	{_Value, Remain} = decode_value(Type, ValRem),
	{again, RecVals, Remain};
rec_field_list(RecVals, N, [Field|Fields], <<Type:8, Bin/binary>>) ->
	% io:format("~p~n", [Field]),
	{Name, ValRem} = decode_cstring(Bin, <<>>),
	case Field of
		docid ->
			BinName = <<"_id">>;
		{Fn, _} ->
			BinName = atom_to_binary(Fn, latin1);
		Fn ->
			BinName = atom_to_binary(Fn, latin1)
	end,
	case BinName of
		Name ->
			case Field of
				{RecName, RecIndex} ->
					<<LRecSize:32/little, RecObj/binary>> = ValRem,
					RecSize = LRecSize - 4,
					<<RecBin:RecSize/binary, Remain/binary>> = RecObj,
					[_|RecFields] = element(RecIndex, ?RECTABLE),
					[Value] = decode_records([], <<LRecSize:32/little, RecBin/binary>>, length(element(RecIndex, ?RECTABLE))+1, 
													RecName, RecIndex, RecFields),
					rec_field_list([{N, Value}|RecVals], N+1, Fields, Remain);
				_ ->
					{Value, Remain} = decode_value(Type, ValRem),
					rec_field_list([{N, Value}|RecVals], N+1, Fields, Remain)
			end;
		_ ->
			rec_field_list(RecVals, N+1, Fields, <<Type:8, Bin/binary>>)
	end.


% bin_to_hexstr(Bin) ->
% 	lists:flatten([io_lib:format("~2.16.0B", [X]) || X <- binary_to_list(Bin)]).
% 
% hexstr_to_bin(S) ->
% 	hexstr_to_bin(S, []).
% hexstr_to_bin([], Acc) ->
% 	list_to_binary(lists:reverse(Acc));
% hexstr_to_bin([X,Y|T], Acc) ->
% 	{ok, [V], []} = io_lib:fread("~16u", [X,Y]),
% 	hexstr_to_bin(T, [V | Acc]).

encode(undefined) ->
	<<>>;
encode(<<>>) ->
	<<>>;
encode(Items) ->
	Bin = lists:foldl(fun(Item, B) -> <<B/binary, (encode_element(Item))/binary>> end, <<>>, Items),
    <<(byte_size(Bin)+5):32/little-signed, Bin/binary, 0:8>>.

encode_element({[_|_] = Name, Val}) ->
	encode_element({list_to_binary(Name),Val});
encode_element({Name, [{_,_}|_] = Items}) ->
	Binary = encode(Items),
	<<3, Name/binary, 0, Binary/binary>>;
encode_element({Name, [_|_] = Value}) ->
	ValueEncoded = encode_cstring(Value),
	<<2, Name/binary, 0, (byte_size(ValueEncoded)):32/little-signed, ValueEncoded/binary>>;
encode_element({Name, <<_/binary>> = Value}) ->
	ValueEncoded = encode_cstring(Value),
	<<2, Name/binary, 0, (byte_size(ValueEncoded)):32/little-signed, ValueEncoded/binary>>;
encode_element({plaintext, Name, Val}) -> % exists for performance reasons.
	<<2, Name/binary, 0, (byte_size(Val)+1):32/little-signed, Val/binary, 0>>;
encode_element({Name, true}) ->
	<<8, Name/binary, 0, 1:8>>;
encode_element({Name, false}) ->
	<<8, Name/binary, 0, 0:8>>;	
% list of lists = array
encode_element({Name, {array, Items}}) ->
  	% ItemNames = [integer_to_list(Index) || Index <- lists:seq(0, length(Items)-1)],
  	% ItemList = lists:zip(ItemNames, Items),
  	% Binary = encode(ItemList),
  	<<4, Name/binary, 0, (encarray([], Items, 0))/binary>>;
encode_element({Name, {bson, Bin}}) ->
	<<3, Name/binary, 0, Bin/binary>>;
encode_element({Name, {inc, Val}}) ->
	encode_element({<<"$inc">>, [{Name, Val}]});
encode_element({Name, {set, Val}}) ->
	encode_element({<<"$set">>, [{Name, Val}]});
encode_element({Name, {push, Val}}) ->
	encode_element({<<"$push">>, [{Name, Val}]});
encode_element({Name, {pushAll, Val}}) ->
	encode_element({<<"$pushAll">>, [{Name, Val}]});
encode_element({Name, {pop, Val}}) ->
	encode_element({<<"$pop">>, [{Name, Val}]});
encode_element({Name, {pull, Val}}) ->
	encode_element({<<"$pull">>, [{Name, Val}]});
encode_element({Name, {pullAll, Val}}) ->
	encode_element({<<"$pullAll">>, [{Name, Val}]});
encode_element({Name, {binary, 2, Data}}) ->
  	<<5, Name/binary, 0, (size(Data)+4):32/little-signed, 2:8, (size(Data)):32/little-signed, Data/binary>>;
encode_element({Name, {binary, SubType, Data}}) ->
  	StringEncoded = encode_cstring(Name),
  	<<5, StringEncoded/binary, (size(Data)):32/little-signed, SubType:8, Data/binary>>;
encode_element({Name, {oid, <<First:8/little-binary-unit:8, Second:4/little-binary-unit:8>>}}) ->
  	FirstReversed = lists:reverse(binary_to_list(First)),
  	SecondReversed = lists:reverse(binary_to_list(Second)),
	OID = list_to_binary(lists:append(FirstReversed, SecondReversed)),
	<<7, Name/binary, 0, OID/binary>>;
encode_element({Name, Value}) when is_integer(Value) ->
	<<18, Name/binary, 0, Value:64/little-signed>>;
encode_element({Name, Value}) when is_float(Value) ->
	<<1, (Name)/binary, 0, Value:64/little-signed-float>>;
encode_element({Name, {obj, []}}) ->
	<<3, Name/binary, 0, (encode([]))/binary>>;	
encode_element({Name, {MegaSecs, Secs, MicroSecs}}) when  is_integer(MegaSecs),is_integer(Secs),is_integer(MicroSecs) ->
  Unix = MegaSecs * 1000000 + Secs,
  Millis = Unix * 1000 + trunc(MicroSecs / 1000),
  <<9, Name/binary, 0, Millis:64/little-signed>>;
encode_element({Name, null}) ->
  <<10, Name/binary>>;
encode_element({Name, {regex, Expression, Flags}}) ->
  ExpressionEncoded = encode_cstring(Expression),
  FlagsEncoded = encode_cstring(Flags),
  <<11, Name/binary, 0, ExpressionEncoded/binary, FlagsEncoded/binary>>;
encode_element({Name, {ref, Collection, <<First:8/little-binary-unit:8, Second:4/little-binary-unit:8>>}}) ->
  CollectionEncoded = encode_cstring(Collection),
  FirstReversed = lists:reverse(binary_to_list(First)),
  SecondReversed = lists:reverse(binary_to_list(Second)),
  OID = list_to_binary(lists:append(FirstReversed, SecondReversed)),
  <<12, Name/binary, 0, (byte_size(CollectionEncoded)):32/little-signed, CollectionEncoded/binary, OID/binary>>;
encode_element({Name, {code, Code}}) ->
  CodeEncoded = encode_cstring(Code),
  <<13, Name/binary, 0, (byte_size(CodeEncoded)):32/little-signed, CodeEncoded/binary>>.

encarray(L, [H|T], N) ->
	encarray([{integer_to_list(N), H}|L], T, N+1);
encarray(L, [], _) ->
	encode(lists:reverse(L)).

encode_cstring(String) ->
    <<(unicode:characters_to_binary(String))/binary, 0:8>>.
	
%% Size has to be greater than 4
decode(<<Size:32/little-signed, Rest/binary>> = Binary) when byte_size(Binary) >= Size, Size > 4 ->
	decode(Rest, Size-4);

decode(_BadLength) ->
	throw({invalid_length}).

decode(Binary, _Size) ->
  	case decode_next(Binary, []) of
    	{BSON, <<>>} ->
      		BSON;
    	{BSON, Rest} ->
			[BSON | decode(Rest)]
  	end.

decode_next(<<>>, Accum) ->
  	{lists:reverse(Accum), <<>>};
decode_next(<<0:8, Rest/binary>>, Accum) ->
	{lists:reverse(Accum), Rest};
decode_next(<<Type:8/little, Rest/binary>>, Accum) ->
  	{Name, EncodedValue} = decode_cstring(Rest, <<>>),
% io:format("Decoding ~p~n", [Type]),
  	{Value, Next} = decode_value(Type, EncodedValue),
  	decode_next(Next, [{Name, Value}|Accum]).

decode_cstring(<<>> = _Binary, _Accum) ->
	throw({invalid_cstring});
decode_cstring(<<0:8, Rest/binary>>, Acc) ->
	{Acc, Rest};
decode_cstring(<<C:8, Rest/binary>>, Acc) ->
	decode_cstring(Rest, <<Acc/binary, C:8>>).
% decode_cstring(<<0:8,Rest/binary>>, Acc) ->
%     {lists:reverse(Acc),Rest};
% decode_cstring(<<C/utf8,Rest/binary>>, Acc) ->
%     decode_cstring(Rest, [C|Acc]).

decode_value(_Type = 1, <<Double:64/little-signed-float, Rest/binary>>) ->
	{Double, Rest};
decode_value(_Type = 2, <<Size:32/little-signed, Rest/binary>>) ->
	StringSize = Size-1,
	<<String:StringSize/binary, 0:8, Remain/binary>> = Rest,
	{String, Remain};
	% {String, RestNext} = decode_cstring(Rest, <<>>),
	% ActualSize = byte_size(Rest) - byte_size(RestNext),
	% case ActualSize =:= Size of
	%     false ->
	%         % ?debugFmt("* ~p =:= ~p -> false", [ActualSize, Size]),
	%         throw({invalid_length, expected, Size, ActualSize});
	%     true ->
	%         {String, RestNext}
	% end;
decode_value(_Type = 3, <<Size:32/little-signed, Rest/binary>> = Binary) when byte_size(Binary) >= Size ->
  	decode_next(Rest, []);
decode_value(_Type = 4, <<Size:32/little-signed, Data/binary>> = Binary) when byte_size(Binary) >= Size ->
  	{Array, Rest} = decode_next(Data, []),
  	{{array,[Value || {_Key, Value} <- Array]}, Rest};
decode_value(_Type = 5, <<_Size:32/little-signed, 2:8/little, BinSize:32/little-signed, BinData:BinSize/binary-little-unit:8, Rest/binary>>) ->
  	{{binary, 2, BinData}, Rest};
decode_value(_Type = 5, <<Size:32/little-signed, SubType:8/little, BinData:Size/binary-little-unit:8, Rest/binary>>) ->
  	{{binary, SubType, BinData}, Rest};
decode_value(_Type = 6, _Binary) ->
  	throw(encountered_undefined);
decode_value(_Type = 7, <<First:8/little-binary-unit:8, Second:4/little-binary-unit:8, Rest/binary>>) ->
  	FirstReversed = lists:reverse(binary_to_list(First)),
  	SecondReversed = lists:reverse(binary_to_list(Second)),
  	OID = list_to_binary(lists:append(FirstReversed, SecondReversed)),
  	{{oid, OID}, Rest};
decode_value(_Type = 8, <<0:8, Rest/binary>>) ->
	{false, Rest};
decode_value(_Type = 8, <<1:8, Rest/binary>>) ->
  	{true, Rest};
decode_value(_Type = 9, <<Millis:64/little-signed, Rest/binary>>) ->
	UnixTime = trunc(Millis / 1000),
  	MegaSecs = trunc(UnixTime / 1000000),
  	Secs = UnixTime - (MegaSecs * 1000000),
  	MicroSecs = (Millis - (UnixTime * 1000)) * 1000,
  	{{MegaSecs, Secs, MicroSecs}, Rest};
decode_value(_Type = 10, Binary) ->
  	{null, Binary};
decode_value(_Type = 11, Binary) ->
  	{Expression, RestWithFlags} = decode_cstring(Binary, <<>>),
  	{Flags, Rest} = decode_cstring(RestWithFlags, <<>>),
  	{{regex, Expression, Flags}, Rest};
decode_value(_Type = 12, <<Size:32/little-signed, Data/binary>> = Binary) when size(Binary) >= Size ->
	{NS, RestWithOID} = decode_cstring(Data, <<>>),
	{{oid, OID}, Rest} = decode_value(7, RestWithOID),
	{{ref, NS, OID}, Rest};
decode_value(_Type = 13, <<_Size:32/little-signed, Data/binary>>) ->
	{Code, Rest} = decode_cstring(Data, <<>>),
	{{code, Code}, Rest};
decode_value(_Type = 14, _Binary) ->
	throw(encountered_ommitted);
decode_value(_Type = 15, _Binary) ->
	throw(encountered_ommitted);
decode_value(_Type = 16, <<Integer:32/little-signed, Rest/binary>>) ->
	{Integer, Rest};
decode_value(_Type = 18, <<Integer:64/little-signed, Rest/binary>>) ->
	{Integer, Rest};
decode_value(_Type = 18, <<Integer:32/little-signed, Rest/binary>>) ->
	{Integer, Rest}.
