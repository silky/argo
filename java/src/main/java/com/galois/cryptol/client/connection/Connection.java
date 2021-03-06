package com.galois.cryptol.client.connection;

import com.eclipsesource.json.*;
import java.util.function.*;
import java.util.*;
import java.io.*;
import com.galois.cryptol.client.connection.ConnectionManager.PipeFactory;

import com.galois.cryptol.client.connection.*;
import com.galois.cryptol.client.connection.json.*;

public class Connection implements AutoCloseable {

    private volatile JsonValue currentState;
    private final JsonConnection jsonConnection;

    public Connection(ProcessBuilder builder,
                      ConnectionManager.PipeFactory<JsonValue> makePipe,
                      Consumer<Throwable> handleException)
        throws IOException {
        this(new ConnectionManager<JsonValue>(builder, makePipe), handleException);
    }

    public Connection(ConnectionManager<JsonValue> connectionManager,
                      Consumer<Throwable> handleException) {
        this(new JsonConnection(connectionManager, handleException));
    }

    public Connection(JsonConnection jsonConnection) {
        this.jsonConnection = jsonConnection;
        this.currentState = null;
    }

    public Connection(Connection other) {
        this.jsonConnection = other.jsonConnection;
        this.currentState = other.currentState;
    }

    public <O, E extends Exception> O call(JsonRpcCall<O, E> call)
        throws E, ConnectionException {
        return jsonConnection.call(new StatefulCall<O, E>(call));
    }

    public void notify(JsonRpcNotification notification)
        throws ConnectionException {
        jsonConnection.notify(new StatefulNotification(notification.method(),
                                                       notification.params()));
    }

    @Override
    public void close() throws IOException {
        this.jsonConnection.close();
    }

    private class StatefulNotification extends JsonRpcNotification {

        public StatefulNotification(String method, JsonValue params) {
            super(method, params);
        }

        public JsonValue params() {
            try {
                JsonObject params = super.params().asObject();
                if (currentState != null) {
                    params.add("state", currentState);
                }
                return Json.object().merge(params);
            } catch (UnsupportedOperationException e) {
                throw new IllegalArgumentException("Stateful call params not an object", e);
            }
        }
    }

    private class StatefulCall<O, E extends Exception> extends JsonRpcCall<O, E> {

        public StatefulCall(JsonRpcCall<O, E> call) {
            // We inherit the special params() behavior from StatefulNotification
            super(new StatefulNotification(call.method(), call.params()),
                  call.decoder, call.handler);
        }

        // And then we further override the decode() behavior to set the state
        public O decode(JsonValue o) {
            try {
                JsonObject callResult = o.asObject();
                synchronized(Connection.this) {
                    var newState = callResult.get("state");
                    // Update the current state if there has been an update
                    currentState = newState != null ? newState : currentState;
                }
                JsonValue answer = callResult.get("answer");
                if (answer != null) {
                    return super.decode(answer);
                } else {
                    throw new IllegalArgumentException("No answer field in stateful result");
                }
            } catch (UnsupportedOperationException e) {
                throw new IllegalArgumentException("Stateful call params not an object", e);
            }
        }
    }
}
