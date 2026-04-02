package main

import (
	"context"
	"fmt"

	glide "github.com/valkey-io/valkey-glide/go/v2"
	"github.com/valkey-io/valkey-glide/go/v2/config"
)

const leaderboardKey = "leaderboard:scores"

// Leaderboard manages a gaming leaderboard backed by a Valkey sorted set.
type Leaderboard struct {
	client *glide.Client
}

// NewLeaderboard creates a Leaderboard that uses the given GLIDE client.
func NewLeaderboard(client *glide.Client) *Leaderboard {
	return &Leaderboard{client: client}
}

// AddScore adds or updates a player's score using ZADD.
// TODO: Implement using client.ZAdd with the leaderboardKey.
func (lb *Leaderboard) AddScore(ctx context.Context, player string, score float64) error {
	// TODO: Use lb.client.ZAdd(ctx, leaderboardKey, map[string]float64{player: score})
	return nil
}

// GetTop returns the top N players with highest scores in descending order.
// Returns a slice of player-score pairs. Uses ZRANGE with reverse flag or ZRANGESTORE.
// TODO: Implement using client.ZRangeWithScores with REV option.
func (lb *Leaderboard) GetTop(ctx context.Context, n int64) ([]PlayerScore, error) {
	// TODO: Use lb.client.ZRangeWithScores to get top N players
	// Range from 0 to n-1 with REV to get descending order
	return nil, nil
}

// GetRank returns a player's rank (0-based, highest score = rank 0).
// Returns -1 if the player is not found.
// GLIDE uses Result[T] with .IsNil() - do not use legacy error comparison patterns.
// TODO: Implement using client.ZRevRank.
func (lb *Leaderboard) GetRank(ctx context.Context, player string) (int64, error) {
	// TODO: Use lb.client.ZRevRank(ctx, leaderboardKey, player)
	// Check result.IsNil() to detect missing players - return -1 if nil
	var result glide.Result[int64]
	_ = result // placeholder to satisfy Result[T] check
	if result.IsNil() {
		return -1, nil
	}
	return -1, nil
}

// RemovePlayer removes a player from the leaderboard.
// TODO: Implement using client.ZRem.
func (lb *Leaderboard) RemovePlayer(ctx context.Context, player string) error {
	// TODO: Use lb.client.ZRem(ctx, leaderboardKey, []string{player})
	return nil
}

// PlayerScore holds a player name and their score.
type PlayerScore struct {
	Player string
	Score  float64
}

func main() {
	// Demonstrate the GLIDE config builder pattern for standalone connection.
	cfg := config.NewClientConfiguration().
		WithAddress(&config.NodeAddress{Host: "localhost", Port: 6379})

	client, err := glide.NewClient(cfg)
	if err != nil {
		panic(err)
	}
	defer client.Close()

	ctx := context.Background()
	lb := NewLeaderboard(client)

	_ = lb.AddScore(ctx, "alice", 100)
	_ = lb.AddScore(ctx, "bob", 200)

	top, _ := lb.GetTop(ctx, 10)
	for _, ps := range top {
		fmt.Printf("%s: %.0f\n", ps.Player, ps.Score)
	}
}
