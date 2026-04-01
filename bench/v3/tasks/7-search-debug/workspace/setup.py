#!/usr/bin/env python3
"""Load 500 product documents into Valkey with a valkey-search index.

Do not modify this file - it is part of the test fixture.
"""

import random
import struct
import time
import valkey

# Deterministic seed for reproducible data
random.seed(42)

PRODUCT_COUNT = 500
EMBEDDING_DIM = 128

# Realistic product data pools
ADJECTIVES = [
    "Premium", "Ultra", "Pro", "Essential", "Classic", "Advanced", "Compact",
    "Deluxe", "Portable", "Smart", "Wireless", "Digital", "Eco", "Heavy-Duty",
    "Lightweight", "Ergonomic", "High-Performance", "Budget", "Luxury", "Mini",
]

NOUNS = {
    "Electronics": [
        "Laptop", "Headphones", "Keyboard", "Mouse", "Monitor", "Tablet",
        "Speaker", "Charger", "Camera", "Drone", "Smartwatch", "Router",
    ],
    "Books": [
        "Novel", "Textbook", "Cookbook", "Biography", "Manual", "Guide",
        "Journal", "Planner", "Atlas", "Dictionary", "Anthology", "Memoir",
    ],
    "Clothing": [
        "Jacket", "Sneakers", "T-Shirt", "Jeans", "Hoodie", "Dress",
        "Shorts", "Sweater", "Boots", "Cap", "Scarf", "Gloves",
    ],
    "Home": [
        "Lamp", "Blender", "Pillow", "Rug", "Shelf", "Candle",
        "Vase", "Clock", "Frame", "Blanket", "Curtain", "Organizer",
    ],
    "Sports": [
        "Basketball", "Yoga Mat", "Dumbbells", "Tennis Racket", "Helmet",
        "Water Bottle", "Backpack", "Cleats", "Goggles", "Gloves",
        "Jump Rope", "Resistance Band",
    ],
}

CATEGORIES = list(NOUNS.keys())

DESCRIPTION_TEMPLATES = [
    "A {adj} {noun} perfect for everyday use. Built with quality materials.",
    "High-quality {adj} {noun} designed for performance and durability.",
    "{adj} {noun} - great value for the price. Customer favorite.",
    "The {adj} {noun} features modern design and reliable construction.",
    "Discover the {adj} {noun}: engineered for comfort and efficiency.",
]


def generate_embedding():
    """Generate a random 128-dimensional float32 vector."""
    vec = [random.gauss(0, 1) for _ in range(EMBEDDING_DIM)]
    return struct.pack(f"{EMBEDDING_DIM}f", *vec)


def generate_product(product_id):
    """Generate a single product with realistic data."""
    category = random.choice(CATEGORIES)
    adj = random.choice(ADJECTIVES)
    noun = random.choice(NOUNS[category])
    name = f"{adj} {noun}"

    template = random.choice(DESCRIPTION_TEMPLATES)
    description = template.format(adj=adj.lower(), noun=noun.lower())

    # Price varies by category
    price_ranges = {
        "Electronics": (50, 1000),
        "Books": (10, 80),
        "Clothing": (20, 300),
        "Home": (15, 500),
        "Sports": (10, 400),
    }
    low, high = price_ranges[category]
    price = round(random.uniform(low, high), 2)

    # Some products have multiple categories (10% chance)
    if random.random() < 0.1:
        extra = random.choice([c for c in CATEGORIES if c != category])
        category = f"{category},{extra}"

    return {
        "name": name,
        "description": description,
        "price": price,
        "category": category,
        "embedding": generate_embedding(),
    }


def wait_for_valkey(client, retries=30, delay=1):
    """Wait for Valkey to be ready."""
    for i in range(retries):
        try:
            client.ping()
            return True
        except (valkey.ConnectionError, ConnectionRefusedError):
            if i < retries - 1:
                time.sleep(delay)
    raise RuntimeError("Valkey not ready after retries")


def create_index(client):
    """Create the FT.SEARCH index."""
    try:
        client.execute_command("FT.DROPINDEX", "products")
    except Exception:
        pass

    client.execute_command(
        "FT.CREATE", "products",
        "ON", "HASH",
        "PREFIX", "1", "product:",
        "SCHEMA",
        "name", "TEXT", "SORTABLE",
        "description", "TEXT",
        "price", "NUMERIC", "SORTABLE",
        "category", "TAG", "SEPARATOR", ",", "CASESENSITIVE",
        "embedding", "VECTOR", "HNSW", "6",
            "TYPE", "FLOAT32",
            "DIM", str(EMBEDDING_DIM),
            "DISTANCE_METRIC", "COSINE",
    )


def load_products(client):
    """Load all products using pipeline for efficiency."""
    pipe = client.pipeline(transaction=False)
    for i in range(1, PRODUCT_COUNT + 1):
        product = generate_product(i)
        key = f"product:{i}"
        pipe.hset(key, mapping={
            "name": product["name"],
            "description": product["description"],
            "price": product["price"],
            "category": product["category"],
            "embedding": product["embedding"],
        })
    pipe.execute()


def verify_index(client):
    """Wait for indexing to complete and verify document count."""
    for _ in range(30):
        info = client.execute_command("FT.INFO", "products")
        # FT.INFO returns a flat list of key-value pairs
        info_dict = {}
        for j in range(0, len(info), 2):
            key = info[j]
            if isinstance(key, bytes):
                key = key.decode()
            info_dict[key] = info[j + 1]

        num_docs = int(info_dict.get("num_docs", 0))
        if num_docs >= PRODUCT_COUNT:
            print(f"[OK] Index ready: {num_docs} documents indexed")
            return True
        time.sleep(0.5)

    print(f"[WARN] Only {num_docs} of {PRODUCT_COUNT} documents indexed")
    return False


def main():
    client = valkey.Valkey(host="localhost", port=6379, decode_responses=False)
    wait_for_valkey(client)
    print("[OK] Connected to Valkey")

    # Clean slate
    client.flushdb()

    create_index(client)
    print("[OK] Index created")

    load_products(client)
    print(f"[OK] Loaded {PRODUCT_COUNT} products")

    verify_index(client)


if __name__ == "__main__":
    main()
