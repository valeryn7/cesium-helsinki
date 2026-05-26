-- =============================================================================
-- DENSIDAD CONSTRUIDA ESTIMADA / FAR POR PARCELA
-- Helsinki 3D / 3DCityDB / PostGIS
--
-- Pregunta:
-- ¿Qué parcelas tienen mayor densidad construida estimada?
--
-- Idea:
-- FOS mira cuánto suelo ocupa la edificación.
-- FAR mira cuánta superficie construida estimada hay respecto al área de parcela.
--
-- Fórmula aproximada:
-- estimated_floors = altura_edificio / 3.2
-- estimated_floor_area_m2 = área ocupada por el edificio dentro de la parcela * estimated_floors
-- FAR = estimated_floor_area_m2 / parcel_area_m2
--
-- Requiere:
-- - analysis.parcels_clean_mat
-- - analysis.building_parcel_intersections_mat
--
-- Estas capas salen de sql/parcel_fos.sql.
--
-- EPSG:4326 = geometría final para GeoServer/Cesium
-- EPSG:3879 = sistema métrico local de Helsinki para áreas/distancias
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS analysis;

DO $$
BEGIN
  IF to_regclass('analysis.parcels_clean_mat') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.parcels_clean_mat. Ejecutá primero sql/parcel_fos.sql';
  END IF;

  IF to_regclass('analysis.building_parcel_intersections_mat') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.building_parcel_intersections_mat. Ejecutá primero sql/parcel_fos.sql';
  END IF;
END $$;

-- =============================================================================
-- 1. Limpiar resultados anteriores
-- =============================================================================

DROP VIEW IF EXISTS analysis.parcel_far_summary CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.building_far_estimate_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.parcel_far_mat CASCADE;

-- =============================================================================
-- 2. Capa técnica por edificio/parcela
--
-- Pregunta:
-- ¿Cuánta superficie construida estimada aporta cada edificio dentro de una parcela?
--
-- Nota:
-- Si un edificio cruza más de una parcela, se usa el área de intersección
-- de ese edificio con cada parcela.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.building_far_estimate_mat AS
SELECT
  row_number() OVER (ORDER BY i.parcel_id, i.gid)::integer AS id,

  i.gid AS building_gid,
  i.building_id,
  i.building_gml_id,
  i.parcel_id,

  i.height_m,
  i.height_category,

  i.footprint_area_m2,
  i.parcel_area_m2,
  i.intersection_area_m2,

  GREATEST(1, ROUND(i.height_m / 3.2)::integer) AS estimated_floors,

  ROUND(
    (
      i.intersection_area_m2 *
      GREATEST(1, ROUND(i.height_m / 3.2)::integer)
    )::numeric,
    2
  ) AS estimated_floor_area_m2,

  ROUND(
    (
      (
        i.intersection_area_m2 *
        GREATEST(1, ROUND(i.height_m / 3.2)::integer)
      ) / NULLIF(i.parcel_area_m2, 0)
    )::numeric,
    3
  ) AS building_far_contribution,

  '¿Cuánta superficie construida estimada aporta este edificio dentro de su parcela?'::text AS question,

  i.geom

FROM analysis.building_parcel_intersections_mat i
WHERE i.intersection_area_m2 > 0;

CREATE UNIQUE INDEX building_far_estimate_mat_id_idx
ON analysis.building_far_estimate_mat (id);

CREATE INDEX building_far_estimate_mat_geom_idx
ON analysis.building_far_estimate_mat
USING gist (geom);

CREATE INDEX building_far_estimate_mat_geom_3879_idx
ON analysis.building_far_estimate_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 3. Capa principal por parcela: FAR / densidad construida estimada
--
-- Pregunta:
-- ¿Qué parcelas tienen mayor densidad construida estimada?
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.parcel_far_mat AS
WITH parcel_areas AS (
  SELECT
    p.parcel_id,
    ST_Area(ST_Transform(p.geom, 3879)) AS parcel_area_m2,
    p.geom
  FROM analysis.parcels_clean_mat p
),
far_by_parcel AS (
  SELECT
    parcel_id,
    COUNT(DISTINCT building_gml_id) AS buildings_count,
    SUM(intersection_area_m2) AS occupied_area_m2,
    SUM(estimated_floor_area_m2) AS estimated_floor_area_m2,
    MAX(height_m) AS max_building_height_m,
    AVG(height_m) AS avg_building_height_m,
    MAX(estimated_floors) AS max_estimated_floors,
    AVG(estimated_floors) AS avg_estimated_floors
  FROM analysis.building_far_estimate_mat
  GROUP BY parcel_id
)
SELECT
  row_number() OVER (ORDER BY p.parcel_id)::integer AS gid,
  p.parcel_id,

  COALESCE(f.buildings_count, 0) AS buildings_count,

  ROUND(p.parcel_area_m2::numeric, 2) AS parcel_area_m2,
  ROUND(COALESCE(f.occupied_area_m2, 0)::numeric, 2) AS occupied_area_m2,
  ROUND(COALESCE(f.estimated_floor_area_m2, 0)::numeric, 2) AS estimated_floor_area_m2,

  ROUND(
    (
      COALESCE(f.estimated_floor_area_m2, 0) / NULLIF(p.parcel_area_m2, 0)
    )::numeric,
    3
  ) AS far_ratio,

  ROUND(COALESCE(f.max_building_height_m, 0)::numeric, 2) AS max_building_height_m,
  ROUND(COALESCE(f.avg_building_height_m, 0)::numeric, 2) AS avg_building_height_m,

  COALESCE(f.max_estimated_floors, 0)::integer AS max_estimated_floors,
  ROUND(COALESCE(f.avg_estimated_floors, 0)::numeric, 2) AS avg_estimated_floors,

  CASE
    WHEN COALESCE(f.estimated_floor_area_m2, 0) / NULLIF(p.parcel_area_m2, 0) >= 3.0 THEN 'HIGH'
    WHEN COALESCE(f.estimated_floor_area_m2, 0) / NULLIF(p.parcel_area_m2, 0) >= 1.5 THEN 'MEDIUM'
    WHEN COALESCE(f.estimated_floor_area_m2, 0) > 0 THEN 'LOW'
    ELSE 'EMPTY'
  END AS far_level,

  '¿Qué parcelas tienen mayor densidad construida estimada?'::text AS question,

  p.geom

FROM parcel_areas p
LEFT JOIN far_by_parcel f
  ON f.parcel_id = p.parcel_id;

CREATE UNIQUE INDEX parcel_far_mat_gid_idx
ON analysis.parcel_far_mat (gid);

CREATE INDEX parcel_far_mat_parcel_id_idx
ON analysis.parcel_far_mat (parcel_id);

CREATE INDEX parcel_far_mat_geom_idx
ON analysis.parcel_far_mat
USING gist (geom);

CREATE INDEX parcel_far_mat_geom_3879_idx
ON analysis.parcel_far_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 4. Vista resumen sin geometría
-- =============================================================================

CREATE VIEW analysis.parcel_far_summary AS
SELECT
  COUNT(*) AS total_parcels,
  COUNT(*) FILTER (WHERE far_level = 'HIGH') AS high_far_parcels,
  COUNT(*) FILTER (WHERE far_level = 'MEDIUM') AS medium_far_parcels,
  COUNT(*) FILTER (WHERE far_level = 'LOW') AS low_far_parcels,
  COUNT(*) FILTER (WHERE far_level = 'EMPTY') AS empty_parcels,

  ROUND(AVG(far_ratio)::numeric, 3) AS avg_far_ratio,
  ROUND(MIN(far_ratio)::numeric, 3) AS min_far_ratio,
  ROUND(MAX(far_ratio)::numeric, 3) AS max_far_ratio,

  ROUND(AVG(parcel_area_m2)::numeric, 2) AS avg_parcel_area_m2,
  ROUND(AVG(estimated_floor_area_m2)::numeric, 2) AS avg_estimated_floor_area_m2,
  ROUND(AVG(max_building_height_m)::numeric, 2) AS avg_max_building_height_m

FROM analysis.parcel_far_mat;

-- =============================================================================
-- 5. Consultas de control
-- =============================================================================

SELECT
  COUNT(*) AS building_far_rows
FROM analysis.building_far_estimate_mat;

SELECT
  COUNT(*) AS parcel_far_rows
FROM analysis.parcel_far_mat;

SELECT *
FROM analysis.parcel_far_summary;

SELECT
  parcel_id,
  buildings_count,
  parcel_area_m2,
  occupied_area_m2,
  estimated_floor_area_m2,
  far_ratio,
  far_level,
  max_building_height_m,
  max_estimated_floors
FROM analysis.parcel_far_mat
ORDER BY far_ratio DESC
LIMIT 20;

-- =============================================================================
-- Colores sugeridos:
--
-- far_level:
-- HIGH    → rojo      #7f1d1d / #ef4444
-- MEDIUM  → naranja   #f97316
-- LOW     → violeta   #8b5cf6
-- EMPTY   → gris      #94a3b8
--
-- Capa principal para publicar:
-- analysis.parcel_far_mat
--
-- Capa técnica opcional:
-- analysis.building_far_estimate_mat
-- =============================================================================
