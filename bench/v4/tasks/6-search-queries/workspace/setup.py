"""Setup script for Task 6: Load 200 products into a valkey-search index.

Connects to Valkey on localhost:6506 and creates an FT index on Hash keys.
Uses deterministic data so query result counts are reproducible.

Index schema:
  FT.CREATE products ON HASH PREFIX 1 product:
    SCHEMA
      name TEXT SORTABLE
      description TEXT
      price NUMERIC SORTABLE
      category TAG SEPARATOR "," CASESENSITIVE
      brand TAG SEPARATOR ","
      rating NUMERIC SORTABLE
      in_stock TAG
"""

import random
import valkey

client = valkey.Valkey(host="localhost", port=6506, decode_responses=True)

# ---------------------------------------------------------------------------
# Deterministic seed
# ---------------------------------------------------------------------------
rng = random.Random(42)

# ---------------------------------------------------------------------------
# Vocabulary for generating product names and descriptions
# ---------------------------------------------------------------------------
ADJECTIVES = [
    "wireless", "portable", "premium", "compact", "ultra", "smart",
    "lightweight", "durable", "advanced", "ergonomic", "vintage",
    "modern", "classic", "professional", "mini", "heavy-duty",
    "waterproof", "solar", "digital", "analog",
]

NOUNS_BY_CATEGORY = {
    "Electronics": [
        "headphones", "speaker", "keyboard", "mouse", "monitor",
        "charger", "cable", "adapter", "webcam", "microphone",
    ],
    "Books": [
        "novel", "textbook", "cookbook", "biography", "guidebook",
        "anthology", "manual", "journal", "almanac", "encyclopedia",
    ],
    "Clothing": [
        "jacket", "shirt", "pants", "hoodie", "sweater",
        "vest", "coat", "shorts", "dress", "blazer",
    ],
    "Home": [
        "lamp", "shelf", "cushion", "blanket", "vase",
        "candle", "rug", "clock", "mirror", "frame",
    ],
    "Sports": [
        "ball", "racket", "gloves", "helmet", "mat",
        "bottle", "bag", "shoes", "band", "weights",
    ],
}

CATEGORIES = list(NOUNS_BY_CATEGORY.keys())
BRANDS = ["BrandA", "BrandB", "BrandC", "BrandD"]

DESC_TEMPLATES = [
    "High quality {adj} {noun} for everyday use",
    "Best selling {adj} {noun} with great reviews",
    "Top rated {adj} {noun} for professionals",
    "{adj} {noun} with fast shipping and warranty",
    "Affordable {adj} {noun} built to last",
]

# ---------------------------------------------------------------------------
# Data generation with guaranteed minimums
# ---------------------------------------------------------------------------

products = []


def make_product(pid, category, price, rating, in_stock):
    """Build a product dict."""
    adj = ADJECTIVES[pid % len(ADJECTIVES)]
    nouns = NOUNS_BY_CATEGORY[category]
    noun = nouns[pid % len(nouns)]
    tmpl = DESC_TEMPLATES[pid % len(DESC_TEMPLATES)]
    brand = BRANDS[pid % len(BRANDS)]
    return {
        "id": pid,
        "name": f"{adj} {noun} {pid}",
        "description": tmpl.format(adj=adj, noun=noun),
        "price": round(price, 2),
        "category": category,
        "brand": brand,
        "rating": round(rating, 1),
        "in_stock": "yes" if in_stock else "no",
    }


pid = 1

# --- Guarantee: 40 Electronics ---
for i in range(40):
    price = rng.uniform(5.0, 999.99)
    rating = rng.uniform(1.0, 5.0)
    in_stock = True
    products.append(make_product(pid, "Electronics", price, rating, in_stock))
    pid += 1

# --- Guarantee: 30 Books ---
for i in range(30):
    price = rng.uniform(5.0, 999.99)
    rating = rng.uniform(1.0, 5.0)
    in_stock = True
    products.append(make_product(pid, "Books", price, rating, in_stock))
    pid += 1

# --- Guarantee: 15 out-of-stock items (spread across categories) ---
for i in range(15):
    cat = CATEGORIES[i % len(CATEGORIES)]
    price = rng.uniform(5.0, 999.99)
    rating = rng.uniform(1.0, 5.0)
    products.append(make_product(pid, cat, price, rating, False))
    pid += 1

# --- Guarantee: 20 items with rating >= 4.5 (Electronics, in stock) ---
for i in range(20):
    price = rng.uniform(5.0, 999.99)
    rating = rng.uniform(4.5, 5.0)
    products.append(make_product(pid, "Electronics", price, rating, True))
    pid += 1

# --- Guarantee: 50 items priced 100-500 (various categories) ---
for i in range(50):
    cat = CATEGORIES[i % len(CATEGORIES)]
    price = rng.uniform(100.0, 500.0)
    rating = rng.uniform(1.0, 5.0)
    # Some already-generated products may also fall in this range,
    # but these 50 are guaranteed.
    products.append(make_product(pid, cat, price, rating, True))
    pid += 1

# --- Fill remaining to reach 200 ---
remaining = 200 - len(products)
for i in range(remaining):
    cat = rng.choice(CATEGORIES)
    price = rng.uniform(5.0, 999.99)
    rating = rng.uniform(1.0, 5.0)
    in_stock = rng.random() > 0.1  # ~90 % in stock
    products.append(make_product(pid, cat, price, rating, in_stock))
    pid += 1

assert len(products) == 200, f"Expected 200 products, got {len(products)}"

# ---------------------------------------------------------------------------
# Compute and print summary stats (used by test.sh for validation)
# ---------------------------------------------------------------------------

electronics_count = sum(1 for p in products if p["category"] == "Electronics")
books_count = sum(1 for p in products if p["category"] == "Books")
price_100_500 = sum(1 for p in products if 100 <= p["price"] <= 500)
high_rated = sum(1 for p in products if p["rating"] >= 4.5)
out_of_stock = sum(1 for p in products if p["in_stock"] == "no")
elec_instock_rating4 = sum(
    1 for p in products
    if p["category"] == "Electronics" and p["rating"] >= 4.0 and p["in_stock"] == "yes"
)

# Products containing "wireless" in name or description
wireless_count = sum(
    1 for p in products
    if "wireless" in p["name"].lower() or "wireless" in p["description"].lower()
)

print(f"Total products:        {len(products)}")
print(f"Electronics:           {electronics_count}")
print(f"Books:                 {books_count}")
print(f"Price 100-500:         {price_100_500}")
print(f"Rating >= 4.5:         {high_rated}")
print(f"Out of stock:          {out_of_stock}")
print(f"Elec+instock+rate>=4:  {elec_instock_rating4}")
print(f"'wireless' matches:    {wireless_count}")

# ---------------------------------------------------------------------------
# Write counts to a JSON file so test.sh can read expected values
# ---------------------------------------------------------------------------
import json

counts = {
    "total": len(products),
    "electronics": electronics_count,
    "books": books_count,
    "price_100_500": price_100_500,
    "high_rated_45": high_rated,
    "out_of_stock": out_of_stock,
    "elec_instock_rate4": elec_instock_rating4,
    "wireless": wireless_count,
    "categories": sorted(set(p["category"] for p in products)),
}
with open("expected_counts.json", "w") as f:
    json.dump(counts, f, indent=2)
print(f"\nWrote expected_counts.json")

# ---------------------------------------------------------------------------
# Load into Valkey
# ---------------------------------------------------------------------------

# Drop index if it exists (ignore errors)
try:
    client.execute_command("FT.DROPINDEX", "products")
    print("Dropped existing 'products' index")
except Exception:
    pass

# Flush product keys
cursor = "0"
while True:
    cursor, keys = client.scan(cursor=cursor, match="product:*", count=100)
    if keys:
        client.delete(*keys)
    if cursor == "0" or cursor == 0:
        break

# Create index
client.execute_command(
    "FT.CREATE", "products",
    "ON", "HASH",
    "PREFIX", "1", "product:",
    "SCHEMA",
    "name", "TEXT", "SORTABLE",
    "description", "TEXT",
    "price", "NUMERIC", "SORTABLE",
    "category", "TAG", "SEPARATOR", ",", "CASESENSITIVE",
    "brand", "TAG", "SEPARATOR", ",",
    "rating", "NUMERIC", "SORTABLE",
    "in_stock", "TAG",
)
print("Created 'products' index")

# Load product data
pipe = client.pipeline()
for p in products:
    key = f"product:{p['id']}"
    pipe.hset(key, mapping={
        "name": p["name"],
        "description": p["description"],
        "price": str(p["price"]),
        "category": p["category"],
        "brand": p["brand"],
        "rating": str(p["rating"]),
        "in_stock": p["in_stock"],
    })
pipe.execute()
print(f"Loaded {len(products)} products")

# Brief wait for indexing
import time
time.sleep(1)

# Verify index is populated
info = client.execute_command("FT.INFO", "products")
# FT.INFO returns a flat list of key-value pairs
info_dict = {}
for i in range(0, len(info), 2):
    info_dict[info[i]] = info[i + 1]
num_docs = info_dict.get("num_docs", "unknown")
print(f"Index reports {num_docs} docs")
print("\n[OK] Setup complete")
