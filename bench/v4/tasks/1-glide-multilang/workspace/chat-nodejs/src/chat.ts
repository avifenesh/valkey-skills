import {
    GlideClusterClient,
    GlideClusterClientConfiguration,
} from "@valkey/valkey-glide";

// Re-export PubSubChannelModes for use in configuration and tests.
const PubSubChannelModes = GlideClusterClientConfiguration.PubSubChannelModes;
export { PubSubChannelModes };

/** A single chat message stored in history. */
export interface ChatMessage {
    sender: string;
    text: string;
    timestamp: number;
}

/**
 * ChatService provides real-time messaging with persistent history.
 *
 * Uses sharded PubSub for delivery and LISTs for message history.
 * Requires two separate GlideClusterClient instances - one for subscriptions
 * (configured with pubsubSubscriptions at creation) and one for publishing.
 *
 * IMPORTANT - GLIDE publish() arg order is REVERSED from legacy clients:
 *   client.publish(message, ch)            // correct - message comes FIRST
 * The message (payload) is the first argument, the destination is second.
 */
export class ChatService {
    private subscriber: GlideClusterClient;
    private publisher: GlideClusterClient;
    private readonly historyPrefix = "chat:history:";
    private readonly channelsKey = "chat:channels";
    private readonly maxHistory = 100;

    /**
     * @param subscriber - GlideClusterClient configured with PubSub subscriptions at creation time
     * @param publisher  - GlideClusterClient for publishing and data operations
     */
    constructor(subscriber: GlideClusterClient, publisher: GlideClusterClient) {
        this.subscriber = subscriber;
        this.publisher = publisher;
    }

    /**
     * Send a message to a channel. Publishes via sharded PubSub and stores
     * in the channel's history list (LPUSH + LTRIM capped at 100 entries).
     * Also tracks the channel in a set for getActiveChannels().
     *
     * GLIDE publish() takes (message, channel) - not (channel, message).
     *
     * TODO: Implement the following steps:
     *   1. Build a ChatMessage with sender, text, and Date.now() timestamp
     *   2. Serialize it to JSON
     *   3. Publish using this.publisher.publish(serializedMessage, channel)
     *   4. LPUSH the message onto historyPrefix + channel
     *   5. LTRIM the list to maxHistory entries
     *   6. SADD the channel name to channelsKey
     */
    async sendMessage(channel: string, sender: string, text: string): Promise<void> {
        // TODO: Build message object
        const _message: ChatMessage = { sender, text, timestamp: Date.now() };
        const _serialized = JSON.stringify(_message);

        // TODO: publish(message, channel) - message first, channel second
        // await this.publisher.publish(_serialized, channel);

        // TODO: LPUSH to history list
        // TODO: LTRIM to cap at maxHistory
        // TODO: SADD channel to active channels set

        throw new Error("TODO: implement sendMessage");
    }

    /**
     * Get the last N messages from a channel's history list.
     *
     * TODO: Use LRANGE on historyPrefix + channel, from 0 to count-1,
     *       then parse each JSON entry back into a ChatMessage.
     */
    async getHistory(channel: string, count: number): Promise<ChatMessage[]> {
        // TODO: Use this.publisher.lrange(historyPrefix + channel, 0, count - 1)
        // TODO: Parse each JSON string into a ChatMessage
        throw new Error("TODO: implement getHistory");
    }

    /**
     * Return the set of channels that have history.
     *
     * TODO: Use SMEMBERS on channelsKey.
     */
    async getActiveChannels(): Promise<string[]> {
        // TODO: Use this.publisher.smembers(this.channelsKey)
        throw new Error("TODO: implement getActiveChannels");
    }
}
