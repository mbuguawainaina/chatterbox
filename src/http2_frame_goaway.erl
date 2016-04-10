-module(http2_frame_goaway).

-include("http2.hrl").

-behaviour(http2_frame).

-export(
   [
    error_code/1,
    format/1,
    new/2,
    read_binary/2,
    to_binary/1
   ]).

-record(goaway, {
          last_stream_id :: stream_id(),
          error_code :: error_code(),
          additional_debug_data = <<>> :: binary()
}).
-type payload() :: #goaway{}.
-export_type([payload/0]).

-spec error_code(payload()) -> error_code().
error_code(#goaway{error_code=EC}) ->
    EC.

-spec format(payload()) -> iodata().
format(Payload) ->
    io_lib:format("[GOAWAY: ~p]", [Payload]).


-spec new(stream_id(), error_code()) -> payload().
new(StreamId, ErrorCode) ->
    #goaway{
       last_stream_id = StreamId,
       error_code = ErrorCode
      }.

-spec read_binary(binary(), frame_header()) ->
                         {ok, payload(), binary()}
                       | {error, stream_id(), error_code(), binary()}.
read_binary(Bin, #frame_header{length=L}) ->
    <<Data:L/binary,Rem/bits>> = Bin,
    <<_R:1,LastStream:31,ErrorCode:32,Extra/bits>> = Data,
    Payload = #goaway{
                 last_stream_id = LastStream,
                 error_code = ErrorCode,
                 additional_debug_data = Extra
                },
    {ok, Payload, Rem}.

-spec to_binary(payload()) -> iodata().
to_binary(#goaway{
             last_stream_id=LSID,
             error_code=EC,
             additional_debug_data=ADD
            }) ->
    [<<0:1,LSID:31,EC:32>>,ADD].
