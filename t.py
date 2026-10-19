
import json
import shutil
import sqlite3
from collections import Counter
import gzip
import mapbox_vector_tile
from shapely.geometry import shape

SOURCE = "assets/squ.mbtiles"
OUTPUT = "assets/squ_styled.mbtiles"

# Preserve the original file.
shutil.copy2(SOURCE, OUTPUT)

source_db = sqlite3.connect(SOURCE)
output_db = sqlite3.connect(OUTPUT)

tiles = source_db.execute(
    "SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles"
).fetchall()

field_types = {}
features_updated = 0

try:
    for z, x, y, tile_data in tiles:
        

        layers_to_encode = []
        
        raw_tile = bytes(tile_data)

        if raw_tile[:2] == b"\x1f\x8b":
            raw_tile = gzip.decompress(raw_tile)

        decoded = mapbox_vector_tile.decode(
            raw_tile,
            default_options={"y_coord_down": True},
        )

        for layer_name, layer in decoded.items():
            features = []

            for feature in layer["features"]:
                props = dict(feature.get("properties", {}))

                raw_tags = props.get("tags", "{}")

                try:
                    tags = (
                        json.loads(raw_tags)
                        if isinstance(raw_tags, str)
                        else {}
                    )
                except (json.JSONDecodeError, TypeError):
                    tags = {}

                if isinstance(tags, dict):
                    for key, value in tags.items():
                        # Avoid replacing existing top-level properties.
                        if key not in props and isinstance(
                            value, (str, int, float, bool)
                        ):
                            props[key] = value
                            field_types.setdefault(key, "String")

                geometry = feature.get("geometry")
                if geometry is None:
                    continue

                encoded_feature = {
                    "geometry": shape(geometry),
                    "properties": props,
                }

                if feature.get("id") is not None:
                    encoded_feature["id"] = feature["id"]

                features.append(encoded_feature)
                features_updated += 1

            layers_to_encode.append({
                "name": layer_name,
                "features": features,
            })

        encoded_tile = mapbox_vector_tile.encode(
            layers_to_encode,
            per_layer_options={
                name: {
                    "extents": layer.get("extent", 4096),
                    # "version": layer.get("version", 2),
                }
                for name, layer in decoded.items()
            },
            default_options={"y_coord_down": True},
        )

        output_db.execute(
            """
            UPDATE tiles
            SET tile_data = ?
            WHERE zoom_level = ?
              AND tile_column = ?
              AND tile_row = ?
            """,
            (encoded_tile, z, x, y),
        )

    # Update the declared vector-layer fields in MBTiles metadata.
    row = output_db.execute(
        "SELECT value FROM metadata WHERE name = 'json'"
    ).fetchone()

    if row:
        metadata = json.loads(row[0])

        for layer in metadata.get("vector_layers", []):
            if layer.get("id") == "squ":
                layer.setdefault("fields", {}).update(field_types)

        output_db.execute(
            "UPDATE metadata SET value = ? WHERE name = 'json'",
            (json.dumps(metadata),),
        )

    output_db.commit()

    print("Created:", OUTPUT)
    print("Tiles processed:", len(tiles))
    print("Features processed:", features_updated)
    print("Additional tag fields:", len(field_types))
    print("Fields:", sorted(field_types))

except Exception:
    output_db.rollback()
    raise

finally:
    source_db.close()
    output_db.close()
