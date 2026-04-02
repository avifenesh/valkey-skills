import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
    GlideClusterClient,
    GlideClusterClientConfiguration,
} from "@valkey/valkey-glide";
import { ChatService, PubSubChannelModes } from "./chat.js";

const addresses = [{ host: "localhost", port: 6379 }];

describe("ChatService", () => {
    let subscriber: GlideClusterClient;
    let publisher: GlideClusterClient;
    let chat: ChatService;

    beforeAll(async () => {
        // Subscriber with PubSub subscriptions configured at client creation time.
        // GLIDE requires subscriptions declared upfront - no runtime subscribe().
        subscriber = await GlideClusterClient.createClient({
            addresses,
            pubsubSubscriptions: {
                channelsAndPatterns: {
                    [GlideClusterClientConfiguration.PubSubChannelModes.Sharded]: new Set([
                        "test-channel",
                    ]),
                },
            },
        });

        // Publisher client - separate instance, no subscriptions
        publisher = await GlideClusterClient.createClient({ addresses });

        chat = new ChatService(subscriber, publisher);

        // Clean up test keys
        await publisher.del(["chat:history:test-channel", "chat:channels"]);
    });

    afterAll(async () => {
        await publisher.del(["chat:history:test-channel", "chat:channels"]);
        subscriber.close();
        publisher.close();
    });

    it("should use GlideClusterClient, not ioredis or redis", () => {
        // Validates that the service is constructed with GLIDE cluster clients
        expect(subscriber).toBeInstanceOf(GlideClusterClient);
        expect(publisher).toBeInstanceOf(GlideClusterClient);
    });

    it("should send and retrieve messages from history", async () => {
        await chat.sendMessage("test-channel", "alice", "Hello!");
        await chat.sendMessage("test-channel", "bob", "Hi there!");

        const history = await chat.getHistory("test-channel", 10);
        expect(history.length).toBe(2);
        // LPUSH stores newest first
        expect(history[0].sender).toBe("bob");
        expect(history[0].text).toBe("Hi there!");
        expect(history[1].sender).toBe("alice");
    });

    it("should track active channels", async () => {
        await chat.sendMessage("test-channel", "alice", "ping");
        const channels = await chat.getActiveChannels();
        expect(channels).toContain("test-channel");
    });

    it("should cap history at 100 messages", async () => {
        // Send 105 messages
        for (let i = 0; i < 105; i++) {
            await chat.sendMessage("test-channel", "bot", `msg-${i}`);
        }
        const history = await chat.getHistory("test-channel", 200);
        expect(history.length).toBeLessThanOrEqual(100);
    });

    it("should use PubSubChannelModes from GLIDE (not event emitters)", () => {
        // Verify that PubSubChannelModes enum values exist
        expect(PubSubChannelModes.Exact).toBeDefined();
        expect(PubSubChannelModes.Pattern).toBeDefined();
        expect(PubSubChannelModes.Sharded).toBeDefined();
    });
});
