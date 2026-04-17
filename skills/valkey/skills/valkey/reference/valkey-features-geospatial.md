# Polygon Geospatial Queries

Use when working with location data and you need to search within arbitrary polygon boundaries, not just circles or rectangles. Available in Valkey 9.0+.

## Background

Geospatial operations have been available since version 3.2. `GEOADD` stores coordinates, `GEOSEARCH` retrieves members within a radius (`BYRADIUS`) or bounding box (`BYBOX`).

Valkey 9.0 adds `BYPOLYGON` support to `GEOSEARCH` for arbitrary polygon queries.

---

## GEOSEARCH BYPOLYGON

### Full Syntax

```
GEOSEARCH key
    BYPOLYGON num-vertices lon1 lat1 lon2 lat2 ... lonN latN
    [ASC | DESC]
    [COUNT count [ANY]]
    [WITHCOORD] [WITHDIST] [WITHHASH]
```

(For `BYRADIUS`/`BYBOX` queries a `FROMMEMBER` or `FROMLONLAT` origin is required; for `BYPOLYGON` it is rejected with a syntax error.)

- `num-vertices` - the first argument after BYPOLYGON specifies how many vertex coordinate pairs follow. Minimum 3.
- Each vertex is a longitude/latitude pair.
- The polygon is automatically closed - do NOT repeat the first vertex as the last one; it wastes a slot and adds an extra edge check.
- Vertices must form a simple (non-self-intersecting) polygon. Winding order (clockwise or counterclockwise) does not matter.
- `FROMMEMBER` and `FROMLONLAT` are NOT used with BYPOLYGON - supplying either returns a syntax error.
- `WITHDIST` with BYPOLYGON returns the distance from the polygon's computed centroid, **not** from any user-supplied point. If you need distance from a known location, compute it client-side or issue a separate `GEODIST`.

### Basic Example

```
# Store some locations
GEOADD locations -122.4194 37.7749 "San Francisco"
GEOADD locations -118.2437 34.0522 "Los Angeles"
GEOADD locations -121.8863 37.3382 "San Jose"
GEOADD locations -117.1611 32.7157 "San Diego"

# Search within a polygon covering Northern California
GEOSEARCH locations BYPOLYGON 4 -123 38 -117 38 -117 37 -123 37 ASC WITHCOORD
# Returns: "San Jose" (within the polygon)
```

### Polygon Covering a State or Region

```
# Define a rough polygon for the San Francisco Bay Area (4 corners - do not repeat the first)
GEOSEARCH locations BYPOLYGON 4 \
  -122.6 37.9 \
  -121.8 37.9 \
  -121.8 37.2 \
  -122.6 37.2 \
  ASC COUNT 100 WITHCOORD WITHDIST
```

---

## Use Cases

### Delivery zone checking

Check if addresses fall within a delivery polygon:

```
# Define delivery zone as a geo set
# (Store potential delivery addresses)
GEOADD delivery:addresses -122.4 37.78 "addr:1001"
GEOADD delivery:addresses -122.5 37.75 "addr:1002"

# Check which addresses fall within the delivery polygon (4 vertices, auto-closed)
GEOSEARCH delivery:addresses BYPOLYGON 4 \
  -122.55 37.82 \
  -122.35 37.82 \
  -122.35 37.72 \
  -122.55 37.72 \
  ASC
```

### Geofencing

Check if tracked assets are within authorized zones:

```
# Store current positions
GEOADD fleet:positions -122.41 37.78 "truck:001"
GEOADD fleet:positions -122.39 37.76 "truck:002"

# Define the warehouse perimeter polygon
GEOSEARCH fleet:positions BYPOLYGON 4 \
  -122.42 37.79 \
  -122.40 37.79 \
  -122.40 37.77 \
  -122.42 37.77 \
  ASC WITHCOORD
```

### Regional analytics

Aggregate data by arbitrary geographic regions (neighborhoods, sales territories, custom zones) that do not fit neatly into circles or rectangles.

---

## Comparison with Existing Search Modes

| Mode | Shape | Available Since | Best For |
|------|-------|----------------|----------|
| `BYRADIUS` | Circle | Redis 6.2 / Valkey 7.2 | "Nearest N within X km" |
| `BYBOX` | Rectangle | Redis 6.2 / Valkey 7.2 | Grid-aligned bounding boxes |
| `BYPOLYGON` | Arbitrary polygon | Valkey 9.0 | Irregular zones, geofences, boundaries |

All three modes support the same optional flags: `ASC`/`DESC`, `COUNT`, `WITHCOORD`, `WITHDIST`, `WITHHASH`.

---

## Storing Coordinates

All geospatial features use `GEOADD` for storage:

```
GEOADD key longitude latitude member [longitude latitude member ...]
```

- Longitude: -180 to 180
- Latitude: -85.05112878 to 85.05112878 (Web Mercator limits)
- Members are unique strings - adding the same member again updates its position
- Internally stored as a sorted set (score = geohash), so sorted set commands work on geo keys

---

## Gotchas

- **Antimeridian (180°/-180° wrap)**. The candidate bounding box is computed as simple min/max lon/lat over the vertices. A polygon that crosses the antimeridian (e.g. spanning 170° to -170° through the Pacific) will produce a bounding box that covers the whole globe and match the wrong members. **Split such polygons into two** - one east of 180°, one west of -180° - and union the results client-side.
- **Self-intersecting polygons**. A figure-8 or "twisted" polygon gives even-odd fill behavior (alternating in/out regions), which is rarely what you want. Keep polygons simple.
- **Very small polygons** (< 100m across) can hit precision limits of the geohash grid. For sub-100m fences, verify with a follow-up GEODIST.

## GEOSEARCHSTORE

`GEOSEARCHSTORE` supports BYPOLYGON with the same syntax, writing matched members (score = geohash) to a destination sorted set. Restriction: the store form rejects `WITHCOORD`, `WITHDIST`, and `WITHHASH` with an error - pick store-and-count OR annotated-results, not both.

## Performance Notes

- `GEOSEARCH` complexity is O(N+log(M)) where N is the number of elements in the grid-aligned bounding box around the shape and M is the number of items inside the shape.
- Polygon point-in-polygon testing adds per-candidate overhead compared to radius/box, but this is negligible for typical polygon sizes (< 100 vertices).
- For very large geo sets (millions of points), combine with `COUNT` to limit result size.

---

