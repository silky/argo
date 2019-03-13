import base64
import socket
import json

from collections import OrderedDict

# Current status:
#  It can currently connect to a server over a socket. Try the following:
#  >>> c = CryptolConnection(PORT)
#  >>> f = c.load_file(FILE)
#  >>> f.result()
#
# TODO:
#  1. State tracking across calls
#  2. Allow multiple replies to messages for intermediate status updates
#  3. Implement the rest of the methods

def encode(string):
    bytestring = string.encode()
    return str(len(bytestring)).encode() + b':' + bytestring + b','

def decode(netstring):
    i = 0
    length_bytes = bytearray(b'')
    while chr(netstring[i]).isdigit():
        length_bytes.append(netstring[i])
        i += 1
    if chr(netstring[i]).encode() != b':':
        raise ValueError("Malformed netstring, missing :")
    length = int(length_bytes.decode())
    i += 1
    out = bytearray(b'')
    for j in range(0, length):
        out.append(netstring[i])
        i += 1
    if chr(netstring[i]).encode() != b',':
        raise ValueError("Malformed netstring, missing ,")
    i += 1
    return (out.decode(), netstring[i:])

def extend_hex(string):
    if len(string) % 2 == 1:
        return '0' + string
    else:
        return string

def fail_with(x):
    "Raise an exception. This is valid in expression positions."
    raise x

class CryptolCode:
    pass

class CryptolLiteral(CryptolCode):
    def __init__(self, code):
        self._code = code

import re

m = r"\{\{([a-zA-Z0-9]+)\}\}"




# TODO Make this more Pythonic by testing for method support rather
# than instances
def to_cryptol_arg(val):
    if isinstance(val, bool):
        return val
    elif val == ():
        return {'expression': 'unit'}
    elif isinstance(val, tuple):
        return {'expression': 'tuple',
                'data': [to_cryptol_arg(x) for x in val]}
    elif isinstance(val, dict):
        return {'expression': 'record',
                'data': {k : to_cryptol_arg(val[k])
                         if isinstance(k, str)
                         else fail_with (TypeError("Record keys must be strings"))
                         for k in val}}
    elif isinstance(val, int):
        return val
    elif isinstance(val, list):
        return {'expression': 'sequence',
                'data': [to_cryptol_arg(v) for v in val]}
    elif isinstance(val, CryptolCode):
        return val.code
    elif isinstance(val, bytes) or isinstance(val, bytearray):
        return {'expression': 'bits',
                'encoding': 'base64',
                'width': 8 * len(val),
                'data': base64.b64encode(val).decode('ascii')}
    else:
        raise TypeError("Unsupported value: " + str(val))

def from_cryptol_arg(val):
    if isinstance(val, bool):
        return val
    elif isinstance(val, int):
        return val
    elif 'expression' in val.keys():
        tag = val['expression']
        if tag == 'unit':
            return ()
        elif tag == 'tuple':
            return (from_cryptol_arg(x) for x in val['data'])
        elif tag == 'record':
            return {k : from_cryptol_arg(val[k]) for k in val['data']}
        elif tag == 'sequence':
            return [from_cryptol_arg(v) for v in val['data']]
        elif tag == 'bits':
            enc = val['encoding']
            if enc == 'base64':
                data = base64.b64decode(val['data'].encode('ascii'))
            elif enc == 'hex':
                data = bytes.fromhex(extend_hex(val['data']))
            else:
                raise ValueError("Unknown encoding " + str(enc))
            return data
        else:
            raise ValueError("Unknown expression tag " + tag)
    else:
        raise TypeError("Unsupported value " + str(val))


class CryptolException(Exception):
    pass

class CryptolInteraction():
    def __init__(self, connection):
        self.connection = connection
        self._raw_response = None
        self.init_state = connection.protocol_state()
        self.params['state'] = self.init_state
        self.request_id = connection.send_message(self.method, self.params)

    def raw_result(self):
        if self._raw_response is None:
            self._raw_response = self.connection.wait_for_reply_to(self.request_id)
        return self._raw_response

    def process_result(self, result):
        raise NotImplementedError('process_result')

class CryptolCommand(CryptolInteraction):

    def _result_and_state(self):
        res = self.raw_result()
        if 'error' in res:
            msg = res['error']['message']
            if 'data' in res['error']:
                msg += " " + str(res['error']['data'])
            raise CryptolException(msg)
        elif 'result' in res:
            return (res['result']['answer'], res['result']['state'])

    def state(self):
        return self._result_and_state()[1]

    def result(self):
        return self.process_result(self._result_and_state()[0])

class CryptolChangeDirectory(CryptolCommand):
    def __init__(self, connection, new_directory):
        self.method = 'change directory'
        self.params = {'directory': new_directory}
        super(CryptolChangeDirectory, self).__init__(connection)

    def process_result(self, res):
        return res

class CryptolLoadModule(CryptolCommand):
    def __init__(self, connection, filename):
        self.method = 'load module'
        self.params = {'file': filename}
        super(CryptolLoadModule, self).__init__(connection)

    def process_result(self, res):
        return res

class CryptolQuery(CryptolInteraction):
    def state(self):
        return self.init_state

    def _result(self):
        res = self.raw_result()
        if 'error' in res:
            msg = res['error']['message']
            if 'data' in res['error']:
                msg += " " + str(res['error']['data'])
            raise CryptolException(msg)
        elif 'result' in res:
            return res['result']['answer']

    def result(self):
        return self.process_result(self._result())

class CryptolEvalExpr(CryptolQuery):
    def __init__(self, connection, expr):
        self.method = 'evaluate expression'
        self.params = {'expression': expr}
        super(CryptolEvalExpr, self).__init__(connection)

    def process_result(self, res):
        return res

class CryptolCall(CryptolQuery):
    def __init__(self, connection, fun, args):
        self.method = 'call'
        self.params = {'function': fun, 'arguments': args}
        super(CryptolCall, self).__init__(connection)

    def process_result(self, res):
        return from_cryptol_arg(res['value'])

class CryptolNames(CryptolQuery):
    def __init__(self, connection):
        self.method = 'visible names'
        self.params = {}
        super(CryptolQuery, self).__init__(connection)

    def process_result(self, res):
        return res

# Must be boxed separately to enable sharing of connections
class IDSource:
    def __init__(self):
        self.next_id = 0

    def get(self):
        self.next_id += 1
        return self.next_id

class CryptolConnection(object):
    def __init__(self, port, parent=None):
        self.port = port

        if parent is None:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.connect(("127.0.0.1", port))
            self.sock.setblocking(False)
            self.buf = bytearray(b'')
            self.replies = {}
            self.ids = IDSource()
            self.most_recent_result = None
        else:
            self.sock = parent.sock
            self.buf = parent.buf
            self.replies = parent.replies
            self.ids = parent.ids
            self.most_recent_result = parent.most_recent_result

    def snapshot(self):
        return CryptolConnection(self.port, parent=self)

    def get_id(self):
        return self.ids.get()

    def buffer_replies(self):
        try:
            arrived = self.sock.recv(4096)
            while arrived != b'':
                self.buf.extend(arrived)
                arrived = self.sock.recv(4096)
            return None
        except BlockingIOError:
            return None

    def get_one_reply(self):
        try:
            (msg, rest) = decode(self.buf)
            self.buf = rest
            return msg
        except (ValueError, IndexError):
            return None

    def process_replies(self):
        self.buffer_replies()
        r = self.get_one_reply()
        while r is not None:
            the_reply = json.loads(r)
            self.replies[the_reply['id']] = the_reply
            r = self.get_one_reply()

    def send_message(self, method, params):
        request_id = self.get_id()
        msg = {'jsonrpc':'2.0',
               'method': method,
               'id': request_id,
               'params': params}
        msg_string = json.dumps(msg)
        msg_bytes = encode(msg_string)
        self.sock.send(msg_bytes)
        return request_id

    def wait_for_reply_to(self, request_id):
        self.process_replies()
        while request_id not in self.replies:
            try:
                #self.sock.setblocking(True)
                self.process_replies()
            finally:
                self.sock.setblocking(False)
        return self.replies[request_id]

    def protocol_state(self):
        if self.most_recent_result is None:
            return []
        else:
            return self.most_recent_result.state()

    # Protocol messages
    def change_directory(self, new_directory):
        self.most_recent_result = CryptolChangeDirectory(self, new_directory)
        return self.most_recent_result

    def load_file(self, filename):
        self.most_recent_result = CryptolLoadModule(self, filename)
        return self.most_recent_result

    def evaluate_expression(self, expression):
        self.most_recent_result = CryptolEvalExpr(self, expression)
        return self.most_recent_result

    def call(self, fun, *args):
        encoded_args = [to_cryptol_arg(a) for a in args]
        self.most_recent_result = CryptolCall(self, fun, encoded_args)
        return self.most_recent_result

    def names(self):
        self.most_recent_result = CryptolNames(self)
        return self.most_recent_result

class CryptolFunctionHandle:
    def __init__(self, connection, name, ty, schema, docs=None):
        self.connection = connection.snapshot()
        self.name = name
        self.ty = ty
        self.schema = schema
        self.docs = docs

        self.__doc__ = "Cryptol type: " + ty
        if self.docs is not None:
            self.__doc__ += "\n" + self.docs

    def __call__(self, *args):
        return self.connection.call(self.name, *args).result()

class CryptolArrowKind:
    def __init__(self, dom, ran):
        self.domain = dom
        self.range = ran

    def __repr__(self):
        return f"CryptolArrowKind({self.domain!r}, {self.range!r})"

def to_kind(k):
    if k == "Type": return "Type"
    elif k == "Num": return "Num"
    elif k == "Prop": return "Prop"
    elif k['kind'] == "arrow":
        return CryptolArrowKind(k['from'], k['to'])

class CryptolProp:
    pass

class UnaryProp(CryptolProp):
    def __init__(self, subject):
        self.subject = subject

class Fin(UnaryProp):
    def __repr__(self):
        return f"Fin({self.subject!r})"

class CryptolType:
    pass

class Var(CryptolType):
    def __init__(self, name, kind):
        self.name = name
        self.kind = kind

    def __repr__(self):
        return f"Var({self.name!r}, {self.kind!r})"


class Function(CryptolType):
    def __init__(self, dom, ran):
        self.domain = dom
        self.range = ran

    def __repr__(self):
        return f"Function({self.domain!r}, {self.range!r})"

class Bitvector(CryptolType):
    def __init__(self, width):
        self.width = width

    def __repr__(self):
        return f"Bitvector({self.width!r})"

class Num(CryptolType):
    def __init__(self, number):
        self.number = number

    def __repr__(self):
        return f"Num({self.number!r})"

class Bit(CryptolType):
    def __init__(self):
        pass

    def __repr__(self):
        return f"Bit()"

class Sequence(CryptolType):
    def __init__(self, length, contents):
        self.length = length
        self.contents = contents

    def __repr__(self):
        return f"Sequence({self.length!r}, {self.contents!r})"

class Inf(CryptolType):
    def __repr__(self):
        return f"Inf()"

class Integer(CryptolType):
    def __repr__(self):
        return f"Integer()"

class Z(CryptolType):
    def __init__(self, modulus):
        self.modulus = modulus

    def __repr__(self):
        return f"Z({self.modulus!r})"


class Plus(CryptolType):
    def __init__(self, left, right):
        self.left = left
        self.right = right

    def __str__(self):
        return f"({self.left} + {self.right})"

    def __repr__(self):
        return f"Plus({self.left!r}, {self.right!r})"

class Minus(CryptolType):
    def __init__(self, left, right):
        self.left = left
        self.right = right

    def __str__(self):
        return f"({self.left} - {self.right})"

    def __repr__(self):
        return f"Minus({self.left!r}, {self.right!r})"

class Times(CryptolType):
    def __init__(self, left, right):
        self.left = left
        self.right = right

    def __str__(self):
        return f"({self.left} * {self.right})"

    def __repr__(self):
        return f"Times({self.left!r}, {self.right!r})"


class Tuple(CryptolType):
    def __init__(self, *types):
        self.types = types
    def __repr__(self):
        return "Tuple(" + ", ".join(map(str, types)) + ")"

class Record(CryptolType):
    def __init__(self, fields):
        self.fields = fields

    def __repr__(self):
        return f"Record({self.fields!r})"

def to_type(t):
    if t['type'] == 'variable':
        return Var(t['name'], to_kind(t['kind']))
    elif t['type'] == 'function':
        return Function(to_type(t['domain']), to_type(t['range']))
    elif t['type'] == 'bitvector':
        return Bitvector(to_type(t['width']))
    elif t['type'] == 'number':
        t['value']
    elif t['type'] == 'Bit':
        return Bit()
    elif t['type'] == 'sequence':
        return Sequence(to_type(t['length']), to_type(t['contents']))
    elif t['type'] == 'inf':
        return Inf()
    elif t['type'] == '+':
        return Plus(*map(to_type, t['arguments']))
    elif t['type'] == '-':
        return Minus(*map(to_type, t['arguments']))
    elif t['type'] == '*':
        return Times(*map(to_type, t['arguments']))
    elif t['type'] == 'tuple':
        return Tuple(*map(to_type, t['contents']))
    elif t['type'] == 'record':
        return Record({k : to_type(t['fields'][k]) for k in t['fields']})
    elif t['type'] == 'Integer':
        return Integer()
    elif t['type'] == 'Z':
        return Z(to_type(t['modulus']))
    else:
        raise NotImplementedError(f"to_type({t!r})")

class CryptolTypeSchema:
    def __init__(self, variables, propositions, body):
        self.variables = variables
        self.propositions = propositions
        self.body = body

    def __repr__(self):
        return f"CryptolTypeSchema({self.variables!r}, {self.propositions!r}, {self.body!r})"

def to_schema(obj):
    return CryptolTypeSchema(OrderedDict((v['name'], to_kind(v['kind']))
                                         for v in obj['forall']),
                             [to_prop(p) for p in obj['propositions']],
                             to_type(obj['type']))

def to_prop(obj):
    if obj['prop'] == 'fin':
        return Fin(to_type(obj['subject']))


class CryptolContext:
    def __init__(self, connection):
        self.connection = connection.snapshot()
        self._defined = {}
        for x in self.connection.names().result():
            if 'documentation' in x:
                self._defined[x['name']] = \
                    CryptolFunctionHandle(self.connection,
                                          x['name'],
                                          x['type string'],
                                          to_schema(x['type']),
                                          x['documentation'])
            else:
                self._defined[x['name']] = \
                    CryptolFunctionHandle(self.connection,
                                          x['name'],
                                          x['type string'],
                                          to_schema(x['type']))

    def __dir__(self):
        return self._defined.keys()

    def __getattr__(self, name):
        if name in self._defined:
            return self._defined[name]
        else:
            raise AttributeError()