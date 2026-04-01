# JDocument / JValue Type Hierarchy

Use when working with the JSON DOM layer - understanding JValue, JDocument, JParser, the RapidJsonAllocator, or how JSON values are stored in memory.

Source: `src/json/dom.h`, `src/rapidjson/document.h`

## Contents

- [Type Hierarchy](#type-hierarchy)
- [RJValue and JValue](#rjvalue-and-jvalue)
- [JDocument](#jdocument)
- [JParser](#jparser)
- [RapidJsonAllocator](#rapidjsonallocator)
- [GenericMember Modifications](#genericmember-modifications)
- [Double Storage as Strings](#double-storage-as-strings)
- [Short String Optimization](#short-string-optimization)
- [Value Flags](#value-flags)
- [Data Union Layout](#data-union-layout)

## Type Hierarchy

The DOM layer wraps RapidJSON types to hide allocator complexity and add module-specific metadata.

```
RJValue  =  rapidjson::GenericValue<UTF8<>, RapidJsonAllocator>
   |
JValue   =  typedef of RJValue (no augmentation)
   |
JDocument : JValue  (adds size + bucket_id bit fields)
```

`RJParser` is `GenericDocument<UTF8<>, RapidJsonAllocator>` - the RapidJSON parse-into-value type. `JParser` inherits from `RJParser` and adds `allocated_size` tracking.

All three types use `RapidJsonAllocator` as the template allocator, which routes every allocation through `dom_alloc`.

## RJValue and JValue

`RJValue` is the typedef for `rapidjson::GenericValue<rapidjson::UTF8<>, RapidJsonAllocator>`. `JValue` is a direct typedef of `RJValue` - no additional members or behavior.

A JValue is a tree node. It does not distinguish between being a document root or a subtree root. All RapidJSON manipulation functions (SetString, AddMember, PushBack, etc.) require the global `allocator` instance:

```cpp
extern RapidJsonAllocator allocator;  // singleton, declared in dom.h
```

JValue is 24 bytes on 64-bit (16 with 48-bit pointer optimization). The internal `Data` union overlaps storage for String, ShortString, Number, ObjectData, ArrayData, HandleData, and Flag. The `Flag` overlay's `payload` plus its 2-byte flags field constitute the full union size.

## JDocument

`JDocument` publicly inherits from `JValue` and adds two bit fields packed into a single `size_t`:

```cpp
struct JDocument : JValue {
    size_t size:56;        // Document memory footprint in bytes
    size_t bucket_id:8;    // Histogram bucket index (0-10)
};
```

Key properties:

- **size (56 bits)** - Total memory of the entire JValue tree under this document. Maintained by the JSON layer (stats module), not by JDocument itself. Maximum representable size is 2^56 bytes (72 PB).
- **bucket_id (8 bits)** - Index into the 11-bucket histogram used by `jsonstats`. Maintained by the stats layer on insert/update/delete.
- **Custom new/delete** - `operator new` calls `dom_alloc`, `operator delete` calls `dom_free`. This ensures JDocument allocations are tracked in memory accounting.
- **No arrays** - `operator new[]` and `operator delete[]` are declared private without definition. JDocument objects are 1:1 with Valkey keys; arrays of them would be a design error.

Access the underlying JValue via `GetJValue()`:

```cpp
JValue& GetJValue();
const JValue& GetJValue() const;
void SetJValue(JValue& rhs);  // move assignment into the JValue base
```

## JParser

`JParser` wraps `RJParser` (which inherits from RJValue) and adds `allocated_size` tracking:

```cpp
struct JParser : RJParser {
    JParser() : RJParser(&allocator), allocated_size(0) {}
    JParser& Parse(const char *json, size_t len);
    JParser& Parse(const std::string_view &sv);
    size_t GetJValueSize() const { return allocated_size + sizeof(RJValue); }
private:
    size_t allocated_size;
};
```

JParser is always created on the stack. During parsing, `dom_alloc`/`dom_free` machinery tracks all allocations made by RapidJSON. The `allocated_size` field captures the total for the parsed tree. `GetJValueSize()` adds `sizeof(RJValue)` because the root value itself (the stack-allocated JParser) is not tracked by dom_alloc.

Typical usage pattern:

```cpp
JParser parser;
parser.Parse(json_buf, buf_len);
if (parser.HasParseError()) {
    return parser.GetParseErrorCode();
}
// Move the parsed value into a JDocument
doc->SetJValue(parser.GetJValue());
```

Parse errors are translated from RapidJSON error codes to `JsonUtilCode`:
- `kParseErrorTermination` -> `JSONUTIL_DOCUMENT_PATH_LIMIT_EXCEEDED`
- All other errors -> `JSONUTIL_JSON_PARSE_ERROR`

## RapidJsonAllocator

The custom allocator is a singleton that delegates to `dom_alloc`/`dom_free`/`dom_realloc`:

```cpp
class RapidJsonAllocator {
public:
    void *Malloc(size_t size)  { return dom_alloc(size); }
    void *Realloc(void *ptr, size_t, size_t newSize) { return dom_realloc(ptr, newSize); }
    static void Free(void *ptr) { dom_free(ptr); }
    static const bool kNeedFree = true;
};
```

All instances compare equal (`operator==` always returns true) because there is one global allocator. The `kNeedFree = true` tells RapidJSON that memory must be explicitly freed (not pooled).

## GenericMember Modifications

Standard RapidJSON `GenericMember` stores a `GenericValue name` field. In valkey-json, the name field is replaced with a `KeyTable_Handle`:

```cpp
template <typename Encoding, typename Allocator>
class GenericMember {
public:
    KeyTable_Handle name;     // interned string handle, not a GenericValue
    GenericValue<Encoding, Allocator> value;
    ~GenericMember() { keyTable->destroyHandle(name); }
};
```

Eliminates per-member string storage for object keys. Keys are interned in the global KeyTable, and member names are 8-byte handles. The destructor releases the KeyTable reference.

For hash table mode, `GenericMemberHT` extends `GenericMember` with linked-list pointers:

```cpp
template <typename Encoding, typename Allocator>
class GenericMemberHT : public GenericMember<Encoding, Allocator> {
public:
    SizeType prev;  // doubly-linked list for insertion order
    SizeType next;
};
```

## Double Storage as Strings

Doubles are stored as their string representation rather than IEEE 754 binary. Preserves exact decimal representation across serialize/deserialize cycles (e.g., `0.1` stays `"0.1"`, not `0.1000000000000000055511151231257827`).

Two storage modes for doubles:

- **kNumberShortDoubleFlag** - String fits inline (up to 21 chars on 64-bit). Uses ShortString layout, same as short strings but flagged as numeric.
- **kNumberDoubleFlag** - String too long for inline. Heap-allocated like kCopyStringFlag.

Both flags include `kNumberFlag | kDoubleFlag`, so `IsDouble()` and `IsNumber()` return true. The string is accessed via `GetDoubleString()` / `GetDoubleStringLength()`. Numerical operations (NUMINCRBY, NUMMULTBY) parse the string, compute, and store the result string.

## Short String Optimization

Strings up to `ShortString::MaxSize` characters (21 on 64-bit, 13 on 32-bit) are stored inline in the JValue's Data union, avoiding a heap allocation:

```cpp
struct ShortString {
    enum { MaxChars = sizeof(Flag::payload) / sizeof(Ch),
           MaxSize = MaxChars - 1,
           LenPos = MaxSize };
    Ch str[MaxChars];
};
```

Length is encoded as `MaxSize - actual_length` in `str[LenPos]`. When `actual_length == MaxSize`, the length byte is zero, which also serves as the null terminator.

Flag `kShortStringFlag` = `kStringType | kStringFlag | kCopyFlag | kInlineStrFlag`.

## Value Flags

The `flags` field is a 14-bit field in the `Flag` struct. Individual flag bits:

| Bit | Value | Name |
|-----|-------|------|
| Bool | 0x0008 | kBoolFlag |
| Number | 0x0010 | kNumberFlag |
| Double | 0x0200 | kDoubleFlag |
| String | 0x0400 | kStringFlag |
| Copy | 0x0800 | kCopyFlag (reused as kVectorFlag for arrays) |
| Inline | 0x1000 | kInlineStrFlag |
| HashTable | 0x2000 | kHashTableFlag |

Composite flag values (computed as type ordinal OR'd with flag bits):

| Flag | Composition | Meaning |
|------|-------------|---------|
| kNullFlag | kNullType | Null value |
| kFalseFlag | kFalseType \| kBoolFlag | Boolean false |
| kTrueFlag | kTrueType \| kBoolFlag | Boolean true |
| kObjectVecFlag | kObjectType | Object with vector storage |
| kObjectHTFlag | kObjectType \| kHashTableFlag | Object with hash table storage |
| kArrayFlag | kArrayType | Array |
| kCopyStringFlag | kStringType \| kStringFlag \| kCopyFlag | Heap-allocated string |
| kShortStringFlag | kStringType \| kStringFlag \| kCopyFlag \| kInlineStrFlag | Inline string |
| kNumberDoubleFlag | kNumberType \| kNumberFlag \| kDoubleFlag | Heap-allocated double-as-string |
| kNumberShortDoubleFlag | kNumberType \| kNumberFlag \| kDoubleFlag \| kInlineStrFlag | Inline double-as-string |

The low 3 bits (`kTypeMask = 0x07`) encode the JSON type for RapidJSON's `GetType()`. The type ordinals are: kNullType=0, kFalseType=1, kTrueType=2, kObjectType=3, kArrayType=4, kStringType=5, kNumberType=6.

## Data Union Layout

The `Data` union is the core storage for every JValue. On 64-bit it is 24 bytes (16 with 48-bit pointer optimization):

```cpp
union Data {
    String s;       // length + hashcode + pointer (16 bytes on 64-bit)
    ShortString ss; // inline chars (payload size from Flag)
    Number n;       // int/uint/int64/uint64/double (8 bytes)
    ObjectData o;   // size + capacity + members pointer (16 bytes on 64-bit)
    ArrayData a;    // size + capacity + elements pointer (16 bytes on 64-bit)
    HandleData h;   // KeyTable_Handle as size_t (8 bytes)
    Flag f;         // payload + 16-bit flags
};
```

The `Flag` overlay provides access to the `flags` (14 bits), `userFlag` (1 bit), and `noescapeFlag` (1 bit) at the end of the union, regardless of which variant is active. The `noescapeFlag` marks strings that need no JSON escaping during serialization, enabling a fast path in the writer.
