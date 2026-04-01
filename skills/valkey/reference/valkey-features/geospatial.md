# Polygon Geospatial Queries

Use when working with location data and you need to search within arbitrary polygon boundaries, not just circles or rectangles. Available in Valkey 9.0+.

## Contents

- Background (line 17)
- GEOSEARCH BYPOLYGON (line 25)
- Use Cases (line 73)
- Comparison with Existing Search Modes (line 119)
- Storing Coordinates (line 131)
- Performance Notes (line 146)

---

## Background

Valkey (and Redis) have supported geospatial operations since version 3.2. The `GEOADD` command stores longitude/latitude coordinates, and `GEOSEARCH` retrieves members within a radius (`BYRADIUS`) or bounding box (`BYBOX`).

Valkey 9.0 adds `BYPOLYGON` support to `GEOSEARCH`, allowing queries against arbitrary polygon shapes.

---

## GEOSEARCH BYPOLYGON

### Full Syntax

```
GEOSEARCH key
    [FROMMEMBER member | FROMLONLAT longitude latitude]
    BYPOLYGON num-vertices lon1 lat1 lon2 lat2 ... lonN latN
    [ASC | DESC]
    [COUNT count [ANY]]
    [WITHCOORD] [WITHDIST] [WITHHASH]
```

- `num-vertices` - the first argument after BYPOLYGON specifies how many vertex coordinate pairs follow
- Each vertex is a longitude/latitude pair
- The polygon is automatically closed (last vertex connects back to first)
- Vertices should be specified in order (clockwise or counterclockwise)
- `FROMMEMBER` and `FROMLONLAT` are NOT used with BYPOLYGON - the center point and bounding box are computed from the polygon vertices

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
# Define a rough polygon for the San Francisco Bay Area
GEOSEARCH locations BYPOLYGON 5 \
  -122.6 37.9 \
  -121.8 37.9 \
  -121.8 37.2 \
  -122.6 37.2 \
  -122.6 37.9 \
  ASC COUNT 100 WITHCOORD WITHDIST
```

---

## Use Cases

### Delivery zone checking

Determine whether a customer's location falls within a delivery service area defined as a polygon:

```
# Define delivery zone as a geo set
# (Store potential delivery addresses)
GEOADD delivery:addresses -122.4 37.78 "addr:1001"
GEOADD delivery:addresses -122.5 37.75 "addr:1002"

# Check which addresses fall within the delivery polygon
GEOSEARCH delivery:addresses BYPOLYGON 5 \
  -122.55 37.82 \
  -122.35 37.82 \
  -122.35 37.72 \
  -122.55 37.72 \
  -122.55 37.82 \
  ASC
```

### Geofencing

Monitor whether tracked assets (vehicles, devices) are within authorized zones:

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

## Performance Notes

- `GEOSEARCH` complexity is O(N+log(M)) where N is the number of elements in the grid-aligned bounding box around the shape and M is the number of items inside the shape
- Polygon point-in-polygon testing adds per-candidate overhead compared to radius/box, but this is negligible for typical polygon sizes (< 100 vertices)
- For very large geo sets (millions of points), combine with `COUNT` to limit result size
- `GEOSEARCHSTORE` also supports BYPOLYGON with the same syntax, storing results into a destination sorted set

---

