# Geospatial Commands

Use when you need location-based features - store locators, proximity search, delivery radius checks, geofencing, or ride-sharing matching by distance.

GLIDE supports the full Valkey geospatial API for indexing and querying locations by longitude/latitude coordinates. Geospatial data is stored internally as sorted sets using geohash-encoded scores. The modern GEOSEARCH/GEOSEARCHSTORE commands (Valkey 6.2+) replace the deprecated GEORADIUS family.

## Supported Commands

All geospatial commands from the Rust core `request_type.rs`:

| Command | RequestType | Description |
|---------|-------------|-------------|
| GEOADD | `GeoAdd` (501) | Add members with longitude/latitude positions |
| GEODIST | `GeoDist` (502) | Get distance between two members |
| GEOHASH | `GeoHash` (503) | Get geohash strings for members |
| GEOPOS | `GeoPos` (504) | Get longitude/latitude of members |
| GEORADIUS | `GeoRadius` (505) | Query by radius (deprecated in Valkey 6.2+) |
| GEORADIUS_RO | `GeoRadiusReadOnly` (506) | Read-only radius query (deprecated in Valkey 6.2+) |
| GEORADIUSBYMEMBER | `GeoRadiusByMember` (507) | Query by radius from member (deprecated in Valkey 6.2+) |
| GEORADIUSBYMEMBER_RO | `GeoRadiusByMemberReadOnly` (508) | Read-only member radius query (deprecated in Valkey 6.2+) |
| GEOSEARCH | `GeoSearch` (509) | Search by radius or box shape |
| GEOSEARCHSTORE | `GeoSearchStore` (510) | Search and store results in a new key |

**Deprecation note**: `GeoRadius`, `GeoRadiusReadOnly`, `GeoRadiusByMember`, and `GeoRadiusByMemberReadOnly` are deprecated since Valkey 6.2+. Use `GeoSearch` and `GeoSearchStore` instead.

## GeoUnit Enum

Distance units for geo commands. Values from Python `GeoUnit` enum in `glide_shared/commands/sorted_set.py`:

| Enum Value | Wire Value | Description |
|------------|------------|-------------|
| `METERS` | `m` | Distance in meters (default) |
| `KILOMETERS` | `km` | Distance in kilometers |
| `MILES` | `mi` | Distance in miles |
| `FEET` | `ft` | Distance in feet |

## Search Shape Options

### GeoSearchByRadius

Circular search area defined by a radius and unit.

- `radius` (float): The search radius
- `unit` (GeoUnit): The distance unit

Sends `BYRADIUS <radius> <unit>` on the wire.

### GeoSearchByBox

Rectangular search area defined by width, height, and unit.

- `width` (float): Box width
- `height` (float): Box height
- `unit` (GeoUnit): The distance unit

Sends `BYBOX <width> <height> <unit>` on the wire.

### GeoSearchCount

Limits the number of results returned.

- `count` (int): Maximum results to return
- `any_option` (bool): When True, returns results as soon as enough matches are found (may not be the closest). Defaults to False.

## Search Origin Options

The `search_from` parameter accepts either:

- A member name (str/bytes) - uses the position of an existing sorted set member as the center
- A `GeospatialData(longitude, latitude)` object - uses explicit coordinates as the center

In Node.js, these are typed as `MemberOrigin` and `CoordOrigin` interfaces.

## Basic Operations (Python)

### Adding Members

```python
from glide import GeospatialData, ConditionalChange

# Add locations with longitude/latitude
count = await client.geoadd(
    "locations",
    {
        "NYC": GeospatialData(-74.006, 40.7128),
        "LA": GeospatialData(-118.2437, 33.9425),
        "Chicago": GeospatialData(-87.6298, 41.8781),
    },
)
# count: 3

# Update only existing members
count = await client.geoadd(
    "locations",
    {"NYC": GeospatialData(-74.006, 40.7127)},
    existing_options=ConditionalChange.XX,
    changed=True,
)
# count: 1 (position updated)
```

### Distance Between Members

```python
from glide import GeoUnit

dist = await client.geodist("locations", "NYC", "LA")
# dist: 3940274.7233 (meters, default)

dist_km = await client.geodist("locations", "NYC", "LA", unit=GeoUnit.KILOMETERS)
# dist_km: 3940.2747

dist_mi = await client.geodist("locations", "NYC", "LA", unit=GeoUnit.MILES)
# dist_mi: 2448.1596
```

### Retrieving Positions and Hashes

```python
# Get longitude/latitude
positions = await client.geopos("locations", ["NYC", "LA", "missing"])
# [[−74.006, 40.7128], [−118.2437, 33.9425], None]

# Get geohash strings
hashes = await client.geohash("locations", ["NYC", "LA"])
# [b"dr5regw2z60", b"9q5ctr186u0"]
```

## Search Operations (Python)

### Search by Radius

```python
from glide import GeoSearchByRadius, GeoUnit, OrderBy, GeoSearchCount

# Find locations within 500 km of NYC
results = await client.geosearch(
    "locations",
    "NYC",
    GeoSearchByRadius(500, GeoUnit.KILOMETERS),
    order_by=OrderBy.ASC,
)
# [b"NYC", ...]

# Search from explicit coordinates with distance info
results = await client.geosearch(
    "locations",
    GeospatialData(-74.0, 40.7),
    GeoSearchByRadius(100, GeoUnit.MILES),
    order_by=OrderBy.ASC,
    with_dist=True,
    count=GeoSearchCount(10),
)
# [[b"NYC", [0.4962]], ...]
```

### Search by Box

```python
from glide import GeoSearchByBox

# Find locations in a 1000x1000 km box centered on Chicago
results = await client.geosearch(
    "locations",
    "Chicago",
    GeoSearchByBox(1000, 1000, GeoUnit.KILOMETERS),
    order_by=OrderBy.ASC,
    with_coord=True,
    with_dist=True,
)
# [[b"Chicago", [0.0, [-87.6298, 41.8781]]], ...]
```

### Store Search Results

```python
from glide import GeoSearchByRadius, GeoUnit

# Store results as a new sorted set (geohash scores)
stored = await client.geosearchstore(
    "nearby_nyc",
    "locations",
    "NYC",
    GeoSearchByRadius(1000, GeoUnit.KILOMETERS),
)
# stored: 2 (number of members stored)

# Store with distance as score instead of geohash
stored = await client.geosearchstore(
    "nearby_nyc_dist",
    "locations",
    "NYC",
    GeoSearchByRadius(1000, GeoUnit.KILOMETERS),
    store_dist=True,
)
```

## Node.js Examples

```typescript
import { GeoUnit, GlideClient, GeospatialData } from "@valkey/valkey-glide";

// Add locations
await client.geoadd("locations", new Map([
    ["NYC", { longitude: -74.006, latitude: 40.7128 }],
    ["LA", { longitude: -118.2437, latitude: 33.9425 }],
]));

// Search by radius from a member
const results = await client.geosearch(
    "locations",
    { member: "NYC" },
    { radius: 500, unit: GeoUnit.KILOMETERS },
    { sortOrder: SortOrder.ASC, count: 10 },
);

// Search by box from coordinates
const boxResults = await client.geosearch(
    "locations",
    { position: { longitude: -74.0, latitude: 40.7 } },
    { width: 1000, height: 1000, unit: GeoUnit.KILOMETERS },
);
```

## Common Use Cases

**Store locator / proximity search**: Add business locations with GEOADD, then use GEOSEARCH with a radius to find nearby stores. Return distances with `with_dist=True` for display.

**Delivery radius check**: Use GEODIST to check if a delivery address (temporary member) is within range of a warehouse. Compare against a threshold distance.

**Geofencing**: Use GEOSEARCH with a box shape to find all entities within a rectangular boundary. Combine with `GeoSearchCount` and the `any_option` for fast approximate checks.

**Ride sharing / matching**: Store driver positions with frequent GEOADD updates (XX flag to only update existing). Search by radius from the rider's location, ordered by ASC to find the nearest available driver.

**Regional aggregation**: Use GEOSEARCHSTORE to materialize nearby results into a new sorted set, then combine with other sorted set operations (ZINTERSTORE) for compound queries.

## Cluster Mode Notes

- GEOSEARCHSTORE requires `destination` and `source` to map to the same hash slot when in cluster mode. Use hash tags (e.g., `{geo}:locations`, `{geo}:results`) to ensure co-location.
- Single-key geo commands (GEOADD, GEODIST, GEOSEARCH) route to the node owning the key's slot automatically.

## Coordinate Limits

Valid ranges per EPSG:900913 / EPSG:3785:
- Longitude: -180 to 180 degrees
- Latitude: -85.05112878 to 85.05112878 degrees

GEOADD returns an error if coordinates fall outside these ranges.

## Related Features

- [Batching](batching.md) - geospatial commands can be included in batches for pipelined execution
- [Server Modules](server-modules.md) - for combined geo + full-text search, use the Search module's GEO field type with FT.SEARCH
