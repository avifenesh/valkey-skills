package main

import (
	"context"
	"testing"

	glide "github.com/valkey-io/valkey-glide/go/v2"
	"github.com/valkey-io/valkey-glide/go/v2/config"
)

// newTestClient creates a GLIDE client connected to localhost:6379 for tests.
func newTestClient(t *testing.T) *glide.Client {
	t.Helper()
	cfg := config.NewClientConfiguration().
		WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})
	client, err := glide.NewClient(cfg)
	if err != nil {
		t.Fatalf("failed to create GLIDE client: %v", err)
	}
	t.Cleanup(func() { client.Close() })
	return client
}

func TestAddScoreAndGetTop(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	lb := NewLeaderboard(client)

	// Clean up before test
	_, _ = client.Del(ctx, []string{leaderboardKey})

	_ = lb.AddScore(ctx, "alice", 100)
	_ = lb.AddScore(ctx, "bob", 250)
	_ = lb.AddScore(ctx, "charlie", 175)

	top, err := lb.GetTop(ctx, 3)
	if err != nil {
		t.Fatalf("GetTop failed: %v", err)
	}
	if len(top) != 3 {
		t.Fatalf("expected 3 players, got %d", len(top))
	}
	// Highest score first
	if top[0].Player != "bob" {
		t.Errorf("expected top player bob, got %s", top[0].Player)
	}
	if top[0].Score != 250 {
		t.Errorf("expected score 250, got %.0f", top[0].Score)
	}
}

func TestGetRankFound(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	lb := NewLeaderboard(client)

	_, _ = client.Del(ctx, []string{leaderboardKey})

	_ = lb.AddScore(ctx, "alice", 100)
	_ = lb.AddScore(ctx, "bob", 250)

	rank, err := lb.GetRank(ctx, "bob")
	if err != nil {
		t.Fatalf("GetRank failed: %v", err)
	}
	// bob has the highest score, so rank 0
	if rank != 0 {
		t.Errorf("expected rank 0 for bob, got %d", rank)
	}
}

func TestGetRankNotFound(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	lb := NewLeaderboard(client)

	_, _ = client.Del(ctx, []string{leaderboardKey})

	rank, err := lb.GetRank(ctx, "nobody")
	if err != nil {
		t.Fatalf("GetRank failed: %v", err)
	}
	if rank != -1 {
		t.Errorf("expected rank -1 for missing player, got %d", rank)
	}
}

func TestRemovePlayer(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	lb := NewLeaderboard(client)

	_, _ = client.Del(ctx, []string{leaderboardKey})

	_ = lb.AddScore(ctx, "alice", 100)
	_ = lb.AddScore(ctx, "bob", 200)

	err := lb.RemovePlayer(ctx, "alice")
	if err != nil {
		t.Fatalf("RemovePlayer failed: %v", err)
	}

	rank, err := lb.GetRank(ctx, "alice")
	if err != nil {
		t.Fatalf("GetRank after removal failed: %v", err)
	}
	if rank != -1 {
		t.Errorf("expected rank -1 for removed player, got %d", rank)
	}
}

func TestUpdateScore(t *testing.T) {
	client := newTestClient(t)
	ctx := context.Background()
	lb := NewLeaderboard(client)

	_, _ = client.Del(ctx, []string{leaderboardKey})

	_ = lb.AddScore(ctx, "alice", 100)
	_ = lb.AddScore(ctx, "alice", 300) // update

	top, err := lb.GetTop(ctx, 1)
	if err != nil {
		t.Fatalf("GetTop failed: %v", err)
	}
	if len(top) != 1 || top[0].Score != 300 {
		t.Errorf("expected updated score 300, got %v", top)
	}
}
