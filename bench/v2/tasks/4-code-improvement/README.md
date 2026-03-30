# Product Cache API

Express API that uses Valkey GLIDE for product data storage.

## Task

Review `app.js` and improve it. Focus on Valkey-specific best practices, performance patterns, and production readiness. Explain each change you make and why.

## Setup

```bash
docker compose up -d
npm install
node app.js
```

## Endpoints

- GET /products - list all
- GET /products/:id - get one
- POST /products - create
- POST /products/bulk - create many
- DELETE /products/:id - delete
- DELETE /products/expired - clean expired
- GET /products/search?q=term - search
- GET /products/category/:cat - by category
- POST /cache/warm - pre-warm cache
