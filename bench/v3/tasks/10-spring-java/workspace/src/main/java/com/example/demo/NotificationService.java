package com.example.demo;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.List;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;
import org.springframework.data.redis.listener.adapter.MessageListenerAdapter;
import org.springframework.stereotype.Service;

@Service
public class NotificationService {

    private final RedisTemplate<String, String> redisTemplate;
    private final List<String> receivedMessages = new CopyOnWriteArrayList<>();

    public NotificationService(RedisTemplate<String, String> redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    public void publish(String channel, String message) {
        redisTemplate.convertAndSend(channel, message);
    }

    public void handleMessage(String message) {
        receivedMessages.add(message);
    }

    public List<String> getReceivedMessages() {
        return receivedMessages;
    }

    public void clearMessages() {
        receivedMessages.clear();
    }

    @Configuration
    static class PubSubConfig {

        @Bean
        RedisMessageListenerContainer redisMessageListenerContainer(
                RedisConnectionFactory connectionFactory,
                NotificationService notificationService) {
            RedisMessageListenerContainer container = new RedisMessageListenerContainer();
            container.setConnectionFactory(connectionFactory);

            MessageListenerAdapter adapter = new MessageListenerAdapter(
                    notificationService, "handleMessage");
            adapter.afterPropertiesSet();

            container.addMessageListener(adapter, new ChannelTopic("notifications"));
            return container;
        }
    }
}
