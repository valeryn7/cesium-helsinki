-- =============================================================================
-- FACTOR DE OCUPACIÓN DEL SUELO REAL - VERSIÓN CORREGIDA
-- Helsinki 3D / 3DCityDB / PostGIS
--
-- Pregunta:
-- ¿Qué porcentaje de cada parcela está ocupado por edificios?
--
-- Corrección:
-- El FOS no se calcula sumando directamente las áreas de intersección,
-- porque eso puede duplicar áreas si hay geometrías superpuestas.
--
-- Ahora:
-- 1. Se calcula la intersección real edificio/parcela.
-- 2. Por parcela, se unen todas las geometrías ocupadas.
-- 3. Recién después se calcula el área ocupada.
--
-- Esto evita valores imposibles como FOS > 100%.
--
-- Requiere:
-- - analysis.urban_building_base_mat
-- - analysis.parcels
--
-- EPSG:4326 = geometría final para GeoServer/Cesium
-- EPSG:3879 = sistema métrico local de Helsinki para áreas/distancias
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS analysis;

DO $$
BEGIN
  IF to_regclass('analysis.urban_building_base_mat') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.urban_building_base_mat. Ejecutá primero la base de edificios.';
  END IF;

  IF to_regclass('analysis.parcels') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.parcels. Importá primero la capa de parcelas como analysis.parcels';
  END IF;
END $$;

-- =============================================================================
-- 1. Limpiar resultados anteriores
-- =============================================================================

DROP VIEW IF EXISTS analysis.parcel_fos_summary CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.parcel_fos_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.building_parcel_coverage_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.building_parcel_intersections_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.parcels_clean_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.buildings_clean_mat CASCADE;

-- =============================================================================
-- 2. Normalizar edificios
--
-- Se limpian las geometrías de edificios:
-- - Se convierten curvas a líneas.
-- - Se fuerzan a 2D.
-- - Se validan.
-- - Se extraen solo polígonos.
-- - Se aplica ST_UnaryUnion para disolver solapamientos internos.
-- - Se guardan como MultiPolygon.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.buildings_clean_mat AS
SELECT
  b.gid,
  b.building_id,
  b.building_gml_id,
  b.height_m,
  b.height_category,
  b.footprint_area_m2,

  ST_Multi(
    ST_CollectionExtract(
      ST_UnaryUnion(
        ST_CollectionExtract(
          ST_MakeValid(
            ST_Force2D(
              ST_CurveToLine(b.geom)
            )
          ),
          3
        )
      ),
      3
    )
  )::geometry(MultiPolygon, 4326) AS geom

FROM analysis.urban_building_base_mat b
WHERE b.geom IS NOT NULL
  AND NOT ST_IsEmpty(b.geom);

CREATE UNIQUE INDEX buildings_clean_mat_gid_idx
ON analysis.buildings_clean_mat (gid);

CREATE INDEX buildings_clean_mat_geom_idx
ON analysis.buildings_clean_mat
USING gist (geom);

CREATE INDEX buildings_clean_mat_geom_3879_idx
ON analysis.buildings_clean_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 3. Normalizar SOLO parcelas cercanas/intersectables al modelo
--
-- Esto evita procesar todas las parcelas completas.
-- Tomamos parcelas que intersectan el área envolvente de los edificios,
-- con un buffer chico por seguridad.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.parcels_clean_mat AS
WITH model_area AS (
  SELECT
    ST_Transform(
      ST_Buffer(
        ST_Envelope(
          ST_Union(
            ST_Transform(geom, 3879)
          )
        ),
        100
      ),
      4326
    ) AS geom
  FROM analysis.buildings_clean_mat
)
SELECT
  p.id::text AS parcel_id,

  ST_Multi(
    ST_CollectionExtract(
      ST_UnaryUnion(
        ST_CollectionExtract(
          ST_MakeValid(
            ST_Force2D(
              ST_CurveToLine(p.geom)
            )
          ),
          3
        )
      ),
      3
    )
  )::geometry(MultiPolygon, 4326) AS geom

FROM analysis.parcels p
JOIN model_area a
  ON ST_Intersects(
    ST_Transform(p.geom, 3879),
    ST_Transform(a.geom, 3879)
  )
WHERE p.geom IS NOT NULL
  AND NOT ST_IsEmpty(p.geom);

CREATE UNIQUE INDEX parcels_clean_mat_parcel_id_idx
ON analysis.parcels_clean_mat (parcel_id);

CREATE INDEX parcels_clean_mat_geom_idx
ON analysis.parcels_clean_mat
USING gist (geom);

CREATE INDEX parcels_clean_mat_geom_3879_idx
ON analysis.parcels_clean_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 4. Intersecciones edificio/parcela
--
-- Pregunta:
-- ¿Qué edificios intersectan con qué parcelas y cuánto ocupan dentro de ellas?
--
-- Corrección:
-- La geometría final de esta capa ahora es la intersección real
-- entre edificio y parcela, no el edificio completo.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.building_parcel_intersections_mat AS
WITH raw_intersections AS (
  SELECT
    b.gid,
    b.building_id,
    b.building_gml_id,
    b.height_m,
    b.height_category,
    b.footprint_area_m2,

    p.parcel_id,

    ST_Area(ST_Transform(p.geom, 3879)) AS parcel_area_m2,

    ST_CollectionExtract(
      ST_MakeValid(
        ST_Intersection(
          ST_Transform(b.geom, 3879),
          ST_Transform(p.geom, 3879)
        )
      ),
      3
    ) AS intersection_geom_3879

  FROM analysis.buildings_clean_mat b
  JOIN analysis.parcels_clean_mat p
    ON ST_Intersects(
      ST_Transform(b.geom, 3879),
      ST_Transform(p.geom, 3879)
    )
),
clean_intersections AS (
  SELECT
    gid,
    building_id,
    building_gml_id,
    height_m,
    height_category,
    footprint_area_m2,
    parcel_id,
    parcel_area_m2,

    ST_UnaryUnion(intersection_geom_3879) AS intersection_geom_3879,

    ST_Area(
      ST_UnaryUnion(intersection_geom_3879)
    ) AS intersection_area_m2

  FROM raw_intersections
  WHERE intersection_geom_3879 IS NOT NULL
    AND NOT ST_IsEmpty(intersection_geom_3879)
),
ranked_intersections AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY gid
      ORDER BY intersection_area_m2 DESC
    ) AS parcel_rank
  FROM clean_intersections
  WHERE intersection_area_m2 > 0
)
SELECT
  row_number() OVER (ORDER BY gid, parcel_id)::integer AS id,

  gid,
  building_id,
  building_gml_id,
  parcel_id,
  height_m,
  height_category,

  ROUND(footprint_area_m2::numeric, 2) AS footprint_area_m2,
  ROUND(parcel_area_m2::numeric, 2) AS parcel_area_m2,
  ROUND(intersection_area_m2::numeric, 2) AS intersection_area_m2,

  ROUND(
    (intersection_area_m2 / NULLIF(parcel_area_m2, 0) * 100)::numeric,
    2
  ) AS intersection_coverage_pct,

  parcel_rank,

  '¿Qué parte de cada parcela es ocupada por la huella de cada edificio?'::text AS question,

  ST_Multi(
    ST_CollectionExtract(
      ST_Transform(intersection_geom_3879, 4326),
      3
    )
  )::geometry(MultiPolygon, 4326) AS geom

FROM ranked_intersections;

CREATE UNIQUE INDEX building_parcel_intersections_mat_id_idx
ON analysis.building_parcel_intersections_mat (id);

CREATE INDEX building_parcel_intersections_mat_geom_idx
ON analysis.building_parcel_intersections_mat
USING gist (geom);

CREATE INDEX building_parcel_intersections_mat_geom_3879_idx
ON analysis.building_parcel_intersections_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 5. Capa por edificio: edificio asociado a su parcela principal
--
-- Pregunta:
-- ¿Qué porcentaje de la parcela ocupa este edificio?
--
-- Esta capa sigue siendo por edificio.
-- Usa parcel_rank = 1 para quedarse con la parcela principal de cada edificio.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.building_parcel_coverage_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  parcel_id,
  height_m,
  height_category,

  footprint_area_m2,
  parcel_area_m2,
  intersection_area_m2,

  ROUND(
    (intersection_area_m2 / NULLIF(parcel_area_m2, 0) * 100)::numeric,
    2
  ) AS building_parcel_coverage_pct,

  CASE
    WHEN intersection_area_m2 / NULLIF(parcel_area_m2, 0) > 0.60 THEN 'HIGH'
    WHEN intersection_area_m2 / NULLIF(parcel_area_m2, 0) > 0.40 THEN 'MEDIUM'
    ELSE 'LOW'
  END AS coverage_level,

  '¿Qué porcentaje de la parcela ocupa cada edificio?'::text AS question,

  geom

FROM analysis.building_parcel_intersections_mat
WHERE parcel_rank = 1;

CREATE UNIQUE INDEX building_parcel_coverage_mat_gid_idx
ON analysis.building_parcel_coverage_mat (gid);

CREATE INDEX building_parcel_coverage_mat_geom_idx
ON analysis.building_parcel_coverage_mat
USING gist (geom);

CREATE INDEX building_parcel_coverage_mat_geom_3879_idx
ON analysis.building_parcel_coverage_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 6. Capa por parcela: FOS real corregido
--
-- Pregunta:
-- ¿Qué porcentaje total de cada parcela está ocupado por edificios?
--
-- Corrección:
-- Antes se usaba:
-- SUM(intersection_area_m2)
--
-- Ahora se usa:
-- ST_Area(ST_UnaryUnion(ST_Collect(geom)))
--
-- Esto une las áreas ocupadas dentro de cada parcela antes de medirlas,
-- evitando contar dos veces superficies superpuestas.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.parcel_fos_mat AS
WITH parcel_areas AS (
  SELECT
    parcel_id,
    ST_Area(ST_Transform(geom, 3879)) AS parcel_area_m2,
    geom
  FROM analysis.parcels_clean_mat
),
coverage AS (
  SELECT
    i.parcel_id,

    COUNT(DISTINCT i.building_gml_id) AS buildings_count,

    LEAST(
      MAX(i.parcel_area_m2),
      ST_Area(
        ST_UnaryUnion(
          ST_Collect(
            ST_Transform(i.geom, 3879)
          )
        )
      )
    ) AS occupied_area_m2,

    MAX(i.height_m) AS max_building_height_m,
    AVG(i.height_m) AS avg_building_height_m

  FROM analysis.building_parcel_intersections_mat i
  GROUP BY i.parcel_id
)
SELECT
  row_number() OVER (ORDER BY p.parcel_id)::integer AS gid,
  p.parcel_id,

  COALESCE(c.buildings_count, 0) AS buildings_count,

  ROUND(p.parcel_area_m2::numeric, 2) AS parcel_area_m2,
  ROUND(COALESCE(c.occupied_area_m2, 0)::numeric, 2) AS occupied_area_m2,

  ROUND(
    LEAST(
      100,
      (COALESCE(c.occupied_area_m2, 0) / NULLIF(p.parcel_area_m2, 0) * 100)
    )::numeric,
    2
  ) AS fos_pct,

  ROUND(COALESCE(c.max_building_height_m, 0)::numeric, 2) AS max_building_height_m,
  ROUND(COALESCE(c.avg_building_height_m, 0)::numeric, 2) AS avg_building_height_m,

  CASE
    WHEN COALESCE(c.occupied_area_m2, 0) / NULLIF(p.parcel_area_m2, 0) > 0.60 THEN 'HIGH'
    WHEN COALESCE(c.occupied_area_m2, 0) / NULLIF(p.parcel_area_m2, 0) > 0.40 THEN 'MEDIUM'
    WHEN COALESCE(c.occupied_area_m2, 0) > 0 THEN 'LOW'
    ELSE 'EMPTY'
  END AS fos_level,

  '¿Qué porcentaje de la parcela está ocupado por edificios?'::text AS question,

  p.geom

FROM parcel_areas p
LEFT JOIN coverage c
  ON c.parcel_id = p.parcel_id;

CREATE UNIQUE INDEX parcel_fos_mat_gid_idx
ON analysis.parcel_fos_mat (gid);

CREATE INDEX parcel_fos_mat_parcel_id_idx
ON analysis.parcel_fos_mat (parcel_id);

CREATE INDEX parcel_fos_mat_geom_idx
ON analysis.parcel_fos_mat
USING gist (geom);

CREATE INDEX parcel_fos_mat_geom_3879_idx
ON analysis.parcel_fos_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 7. Vista resumen sin geometría
-- =============================================================================

CREATE VIEW analysis.parcel_fos_summary AS
SELECT
  COUNT(*) AS total_parcels,
  COUNT(*) FILTER (WHERE fos_level = 'HIGH') AS high_fos_parcels,
  COUNT(*) FILTER (WHERE fos_level = 'MEDIUM') AS medium_fos_parcels,
  COUNT(*) FILTER (WHERE fos_level = 'LOW') AS low_fos_parcels,
  COUNT(*) FILTER (WHERE fos_level = 'EMPTY') AS empty_parcels,

  ROUND(AVG(fos_pct)::numeric, 2) AS avg_fos_pct,
  ROUND(MIN(fos_pct)::numeric, 2) AS min_fos_pct,
  ROUND(MAX(fos_pct)::numeric, 2) AS max_fos_pct,

  ROUND(AVG(parcel_area_m2)::numeric, 2) AS avg_parcel_area_m2,
  ROUND(AVG(occupied_area_m2)::numeric, 2) AS avg_occupied_area_m2

FROM analysis.parcel_fos_mat;

-- =============================================================================
-- 8. Consultas de control
-- =============================================================================

SELECT
  COUNT(*) AS cleaned_buildings
FROM analysis.buildings_clean_mat;

SELECT
  COUNT(*) AS cleaned_parcels_near_model
FROM analysis.parcels_clean_mat;

SELECT
  COUNT(*) AS building_parcel_matches
FROM analysis.building_parcel_coverage_mat;

SELECT
  COUNT(*) AS parcel_fos_rows
FROM analysis.parcel_fos_mat;

SELECT *
FROM analysis.parcel_fos_summary;

SELECT
  parcel_id,
  buildings_count,
  parcel_area_m2,
  occupied_area_m2,
  fos_pct,
  fos_level,
  max_building_height_m
FROM analysis.parcel_fos_mat
ORDER BY fos_pct DESC
LIMIT 20;

-- =============================================================================
-- 9. Control extra: detectar si todavía aparece algún FOS imposible
-- =============================================================================

SELECT
  parcel_id,
  parcel_area_m2,
  occupied_area_m2,
  fos_pct,
  buildings_count
FROM analysis.parcel_fos_mat
WHERE fos_pct > 100
ORDER BY fos_pct DESC;