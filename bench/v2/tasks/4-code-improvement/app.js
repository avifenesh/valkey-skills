import { GlideClusterClient } from "@valkey/valkey-glide";
import express from "express";

const app = express();
app.use(express.json());

// Connect to Valkey
const client = await GlideClusterClient.createClient({
  addresses: [{ host: "localhost", port: 6379 }],
});

// GET /products - list all products
app.get("/products", async (req, res) => {
  // Get all product keys
  const keys = await client.customCommand(["KEYS", "product:*"]);

  if (!keys || keys.length === 0) {
    return res.json([]);
  }

  // Fetch each product individually
  const products = await Promise.all(
    keys.map(async (key) => {
      const data = await client.get(key);
      return data ? JSON.parse(data) : null;
    })
  );

  res.json(products.filter(Boolean));
});

// GET /products/:id
app.get("/products/:id", async (req, res) => {
  const data = await client.get(`product:${req.params.id}`);
  if (!data) return res.status(404).json({ error: "Not found" });
  res.json(JSON.parse(data));
});

// POST /products - create a product
app.post("/products", async (req, res) => {
  const product = req.body;
  product.id = product.id || Date.now().toString();
  await client.set(`product:${product.id}`, JSON.stringify(product));
  res.status(201).json(product);
});

// POST /products/bulk - create many products
app.post("/products/bulk", async (req, res) => {
  const products = req.body;

  // Save each product one at a time
  for (const product of products) {
    await client.set(`product:${product.id}`, JSON.stringify(product));
  }

  res.json({ created: products.length });
});

// DELETE /products/:id
app.delete("/products/:id", async (req, res) => {
  await client.del([`product:${req.params.id}`]);
  res.status(204).send();
});

// DELETE /products/expired - clean up old products
app.delete("/products/expired", async (req, res) => {
  const keys = await client.customCommand(["KEYS", "product:*"]);
  let deleted = 0;

  for (const key of keys) {
    const data = await client.get(key);
    if (data) {
      const product = JSON.parse(data);
      if (product.expiresAt && new Date(product.expiresAt) < new Date()) {
        await client.del([key]);
        deleted++;
      }
    }
  }

  res.json({ deleted });
});

// GET /products/search?q=term
app.get("/products/search", async (req, res) => {
  const keys = await client.customCommand(["KEYS", "product:*"]);
  const results = [];

  for (const key of keys) {
    const data = await client.get(key);
    if (data) {
      const product = JSON.parse(data);
      if (product.name && product.name.toLowerCase().includes(req.query.q.toLowerCase())) {
        results.push(product);
      }
    }
  }

  res.json(results);
});

// GET /products/category/:cat - get products by category
app.get("/products/category/:cat", async (req, res) => {
  const keys = await client.customCommand(["KEYS", "product:*"]);
  const results = [];

  for (const key of keys) {
    const data = await client.get(key);
    if (data) {
      const product = JSON.parse(data);
      if (product.category === req.params.cat) {
        results.push(product);
      }
    }
  }

  // Sort by price
  const sorted = results.sort((a, b) => a.price - b.price);
  res.json(sorted);
});

// POST /cache/warm - pre-warm cache from database
app.post("/cache/warm", async (req, res) => {
  const productIds = req.body.ids;

  // Fetch from "database" and cache each one
  for (const id of productIds) {
    const product = await fetchFromDatabase(id);
    if (product) {
      await client.set(`product:${id}`, JSON.stringify(product));
    }
  }

  res.json({ warmed: productIds.length });
});

async function fetchFromDatabase(id) {
  // Simulate DB fetch
  return { id, name: `Product ${id}`, price: Math.random() * 100, category: "general" };
}

app.listen(3000, () => console.log("Server running on port 3000"));
