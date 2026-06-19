-- =============================================================================
-- SOMBRA FISICA APROXIMADA SOBRE ESPACIOS VERDES
-- Helsinki 3D / 3DCityDB / PostGIS
--
-- Pregunta:
-- ¿Qué sectores de espacios verdes reciben mayor sombra proyectada por edificios?
--
-- Importante:
-- Esto no es ray tracing 3D ni simulacion horaria completa.
-- Se usa una posicion solar fija y se proyecta una huella 2D aproximada.
--
-- Parametros por defecto (invierno, mediodia aproximado en Helsinki):
-- - sun_azimuth_deg   = 180 (sol al sur)
-- - sun_elevation_deg = 6   (sol bajo)
--
-- Geometria final: EPSG:4326
-- Calculos metricos: EPSG:3879
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS analysis;

DO $$
BEGIN
  IF to_regclass('analysis.urban_building_base_mat') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.urban_building_base_mat. Ejecutá import_gml_and_generate.sh para regenerar base de edificios';
  END IF;

  IF to_regclass('analysis.green_areas_near_model_mat') IS NULL THEN
    RAISE EXCEPTION 'Falta analysis.green_areas_near_model_mat. Ejecutá primero sql/green_spaces.sql';
  END IF;
END $$;

-- =============================================================================
-- 1. Limpiar resultados anteriores
-- =============================================================================

DROP VIEW IF EXISTS analysis.shadow_risk_green_summary CASCADE;
DROP VIEW IF EXISTS analysis.high_shadow_risk_green_points CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.shadow_risk_green_mat CASCADE;

-- =============================================================================
-- 2. Capa principal: sombra proyectada sobre espacios verdes
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.shadow_risk_green_mat AS
WITH params AS (
  SELECT
    180.0::double precision AS sun_azimuth_deg,
    6.0::double precision AS sun_elevation_deg
),
base_buildings AS (
  SELECT
    b.gid AS building_gid,
    b.building_gml_id::text AS source_id,
    b.height_m,
    b.height_category,
    ST_Transform(b.geom, 3879) AS geom_3879
  FROM analysis.urban_building_base_mat b
  WHERE b.geom IS NOT NULL
    AND NOT ST_IsEmpty(b.geom)
    AND b.height_m > 0
),
shadow_vectors AS (
  SELECT
    b.*,
    p.sun_azimuth_deg,
    p.sun_elevation_deg,
    (p.sun_azimuth_deg + 180.0 - 360.0 * floor((p.sun_azimuth_deg + 180.0) / 360.0)) AS shadow_azimuth_deg,
    GREATEST(
      b.height_m / NULLIF(tan(radians(p.sun_elevation_deg)), 0),
      0
    ) AS shadow_length_m
  FROM base_buildings b
  CROSS JOIN params p
),
shadow_polygons AS (
  SELECT
    v.building_gid,
    v.source_id,
    v.height_m,
    v.height_category,
    v.geom_3879 AS building_geom_3879,
    v.sun_azimuth_deg,
    v.sun_elevation_deg,
    v.shadow_azimuth_deg,
    ROUND(v.shadow_length_m::numeric, 2) AS shadow_length_m,
    ST_Multi(
      ST_CollectionExtract(
        ST_MakeValid(
          ST_Buffer(
            ST_ConvexHull(
              ST_Collect(
                v.geom_3879,
                ST_Translate(
                  v.geom_3879,
                  v.shadow_length_m * sin(radians(v.shadow_azimuth_deg)),
                  v.shadow_length_m * cos(radians(v.shadow_azimuth_deg))
                )
              )
            ),
            0
          )
        ),
        3
      )
    )::geometry(MultiPolygon, 3879) AS shadow_geom_3879
  FROM shadow_vectors v
),
intersections AS (
  SELECT
    s.building_gid,
    s.source_id,
    s.height_m,
    s.height_category,
    g.id AS green_id,
    s.sun_azimuth_deg,
    s.sun_elevation_deg,
    s.shadow_azimuth_deg,
    s.shadow_length_m,
    ST_Distance(s.building_geom_3879, ST_Transform(g.geom, 3879)) AS distance_to_green_m,
    ST_Area(
      ST_Intersection(s.shadow_geom_3879, ST_Transform(g.geom, 3879))
    ) AS shadow_on_green_m2,
    ST_Area(ST_Transform(g.geom, 3879)) AS green_area_m2,
    ST_Transform(
      ST_Multi(
        ST_CollectionExtract(
          ST_MakeValid(
            ST_Intersection(s.shadow_geom_3879, ST_Transform(g.geom, 3879))
          ),
          3
        )
      ),
      4326
    )::geometry(MultiPolygon, 4326) AS geom
  FROM shadow_polygons s
  JOIN analysis.green_areas_near_model_mat g
    ON ST_Intersects(s.shadow_geom_3879, ST_Transform(g.geom, 3879))
)
SELECT
  row_number() OVER (ORDER BY i.building_gid, i.green_id)::integer AS gid,
  i.building_gid,
  i.source_id,
  i.height_m,
  i.height_category,
  i.green_id,
  i.sun_azimuth_deg,
  i.sun_elevation_deg,
  i.shadow_azimuth_deg,
  i.shadow_length_m,
  ROUND(i.distance_to_green_m::numeric, 2) AS distance_to_green_m,
  ROUND(i.shadow_on_green_m2::numeric, 2) AS shadow_on_green_m2,
  ROUND(i.green_area_m2::numeric, 2) AS green_area_m2,
  ROUND((i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0))::numeric, 4) AS shadow_risk_score,
  CASE
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.20 THEN 'VERY_HIGH'
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.10 THEN 'HIGH'
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.03 THEN 'MEDIUM'
    ELSE 'LOW'
  END AS shadow_risk_level,
  CASE
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.20 THEN
      'Cobertura de sombra muy alta sobre el espacio verde (escenario solar fijo)'
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.10 THEN
      'Cobertura de sombra alta sobre el espacio verde (escenario solar fijo)'
    WHEN (i.shadow_on_green_m2 / NULLIF(i.green_area_m2, 0)) >= 0.03 THEN
      'Cobertura de sombra media sobre el espacio verde (escenario solar fijo)'
    ELSE
      'Cobertura de sombra baja sobre el espacio verde (escenario solar fijo)'
  END AS shadow_risk_reason,
  '¿Qué sectores de espacios verdes quedan bajo sombra proyectada en un escenario solar fijo?'::text AS question,
  i.geom
FROM intersections i
WHERE i.shadow_on_green_m2 > 0
  AND i.geom IS NOT NULL
  AND NOT ST_IsEmpty(i.geom);

CREATE UNIQUE INDEX shadow_risk_green_mat_gid_idx
ON analysis.shadow_risk_green_mat (gid);

CREATE INDEX shadow_risk_green_mat_level_idx
ON analysis.shadow_risk_green_mat (shadow_risk_level);

CREATE INDEX shadow_risk_green_mat_green_idx
ON analysis.shadow_risk_green_mat (green_id);

CREATE INDEX shadow_risk_green_mat_geom_idx
ON analysis.shadow_risk_green_mat
USING gist (geom);

CREATE INDEX shadow_risk_green_mat_geom_3879_idx
ON analysis.shadow_risk_green_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 3. Vista filtrada: solo riesgos altos / muy altos
-- =============================================================================

CREATE VIEW analysis.high_shadow_risk_green_points AS
SELECT *
FROM analysis.shadow_risk_green_mat
WHERE shadow_risk_level IN ('HIGH', 'VERY_HIGH');

-- =============================================================================
-- 4. Vista resumen sin geometría
-- =============================================================================

CREATE VIEW analysis.shadow_risk_green_summary AS
SELECT
  COUNT(*) AS total_shadow_patches,
  COUNT(*) FILTER (WHERE shadow_risk_level = 'VERY_HIGH') AS very_high_shadow_risk,
  COUNT(*) FILTER (WHERE shadow_risk_level = 'HIGH') AS high_shadow_risk,
  COUNT(*) FILTER (WHERE shadow_risk_level = 'MEDIUM') AS medium_shadow_risk,
  COUNT(*) FILTER (WHERE shadow_risk_level = 'LOW') AS low_shadow_risk,
  ROUND(AVG(height_m)::numeric, 2) AS avg_height_m,
  ROUND(MAX(height_m)::numeric, 2) AS max_height_m,
  ROUND(AVG(shadow_length_m)::numeric, 2) AS avg_shadow_length_m,
  ROUND(MAX(shadow_length_m)::numeric, 2) AS max_shadow_length_m,
  ROUND(SUM(shadow_on_green_m2)::numeric, 2) AS total_shadow_on_green_m2,
  ROUND(AVG(shadow_risk_score)::numeric, 4) AS avg_shadow_risk_score,
  ROUND(MAX(shadow_risk_score)::numeric, 4) AS max_shadow_risk_score
FROM analysis.shadow_risk_green_mat;

-- =============================================================================
-- 5. Consultas de control
-- =============================================================================

SELECT *
FROM analysis.shadow_risk_green_summary;

SELECT
  source_id,
  green_id,
  height_m,
  shadow_length_m,
  shadow_on_green_m2,
  shadow_risk_score,
  shadow_risk_level,
  shadow_risk_reason
FROM analysis.shadow_risk_green_mat
ORDER BY
  CASE shadow_risk_level
    WHEN 'VERY_HIGH' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    ELSE 4
  END,
  shadow_risk_score DESC
LIMIT 25;

-- =============================================================================
-- Colores sugeridos:
--
-- VERY_HIGH -> rojo oscuro  #7f1d1d
-- HIGH      -> rojo         #ef4444
-- MEDIUM    -> naranja      #f97316
-- LOW       -> amarillo     #facc15
-- =============================================================================
