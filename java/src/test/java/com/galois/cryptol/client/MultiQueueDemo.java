package com.galois.cryptol.client;

import java.util.*;
import java.io.*;
import java.net.*;
import java.util.concurrent.*;
import java.util.function.*;

import com.eclipsesource.json.*;
import com.galois.cryptol.client.*;
import com.galois.cryptol.client.connection.queue.*;

class MultiQueueDemo {

    public static void main(String[] args) {
        if (args.length == 3) {
            multiQueueDemo(Integer.parseInt(args[0]),
                           Double.parseDouble(args[1]),
                           Integer.parseInt(args[2]));
        } else {
            System.err.println("Wrong number of arguments: please specify (channels, mean delay, timeout)");
            System.exit(1);
        }
    }

    // Visual demo of concurrent keyed channel: run a receiving and a sending
    // thread per channel, each with random delay between send() and request()
    // calls, displaying the method calls in a table. The simulation lasts for
    // the timeout parameter, in seconds
    public static void multiQueueDemo(int channelCount, double meanDelay, int timeout) {
        // Channels
        var channels = new ConcurrentMultiQueue<Integer, Integer>();

        // Sending threads
        var sending = new ArrayList<Runnable>();
        for (int c = 0; c < channelCount; c++) {
            int channel = c;
            sending.add(() -> {
                    int message = 0;
                    while (true) {
                        long wait = (long)(2 * 1000 * meanDelay * Math.random());
                        try {
                            TimeUnit.MILLISECONDS.sleep(wait);
                        } catch (InterruptedException e) {
                            throw new RuntimeException(e);
                        }
                        try {
                            channels.send(channel, message);
                        } catch (QueueClosedException e) {
                            break;
                        }
                        synchronized(System.out) {
                            for (int i = 0; i < channel; i++) System.out.print("\t\t\t\t");
                            System.out.println(channel + ": SEND " + message);
                        }
                        message++;
                    }
                    synchronized(System.out) {
                        for (int i = 0; i < channel; i++) System.out.print("\t\t\t\t");
                        System.out.println(channel + ": STOPPED");
                    }
                });
        }

        // Receiving threads
        var receiving = new ArrayList<Runnable>();
        for (int c = 0; c < channelCount; c++) {
            int channel = c;
            receiving.add(() -> {
                    while (true) {
                        long wait = (long)(2 * 1000 * meanDelay * Math.random());
                        try {
                            TimeUnit.MILLISECONDS.sleep(wait);
                        } catch (InterruptedException e) {
                            throw new RuntimeException(e);
                        }
                        synchronized(System.out) {
                            for (int i = 0; i < channel; i++) System.out.print("\t\t\t\t");
                            System.out.println("\t\t" + channel + ": REQUEST ");
                        }
                        Integer message;
                        try {
                            message = channels.request(channel);
                        } catch (QueueClosedException e) {
                            break;
                        }
                        synchronized(System.out) {
                            for (int i = 0; i < channel; i++) System.out.print("\t\t\t\t");
                            System.out.println("\t\t" + channel + ": RECEIVE " + message);
                        }
                    }
                    synchronized(System.out) {
                        for (int i = 0; i < channel; i++) System.out.print("\t\t\t\t");
                        System.out.println("\t\t" + channel + ": CANCELLED ");
                    }
                });
        }

        // Start all threads
        System.out.println();
        for (var f : sending)   (new Thread(f)).start();
        for (var f : receiving) (new Thread(f)).start();

        (new Thread(() -> {
                try {
                    TimeUnit.SECONDS.sleep(timeout);
                    synchronized(System.out) {
                        channels.close();
                        for (int i = 0; i < channelCount; i++) {
                            System.out.print("--------------------------------");
                        }
                        System.out.println();
                    }
                    channels.close();
                    synchronized(System.out) {
                        channels.close();
                        for (int i = 0; i < channelCount; i++) {
                            System.out.print("--------------------------------");
                        }
                        System.out.println();
                    }
                } catch (InterruptedException e) {
                }
        })).start();
    }
}
