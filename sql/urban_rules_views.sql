-- =============================================================================
-- urban_rules_views.sql
-- Helsinki 3D / CityGML / 3DCityDB v5 / PostGIS
--
-- Objetivo:
-- Crear varias capas (materialized views) en el schema analysis para publicarlas
-- en GeoServer y consumirlas desde Cesium/QGIS como WFS/GeoJSON.
--
-- IMPORTANTE:
-- Estas NO son normas oficiales de Helsinki.
-- Son reglas urbanas aproximadas / criterios de análisis para demostrar consultas
-- espaciales sobre un modelo CityGML 3D.
--
-- Sistema de trabajo:
-- - Las geometrías finales quedan en EPSG:4326 para GeoServer/Cesium.
-- - Las distancias y áreas se calculan transformando a EPSG:3879.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS analysis;

-- -----------------------------------------------------------------------------
-- Limpiar vistas anteriores
-- -----------------------------------------------------------------------------

DROP MATERIALIZED VIEW IF EXISTS analysis.combined_urban_rules_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule6_far_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule5_max_height_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule4_min_height_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule3_coverage_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule2_height_ratio_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.rule1_building_spacing_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.urban_building_base_mat CASCADE;

-- =============================================================================
-- 0) CAPA BASE: edificios con huella, altura y métricas
--
-- Pregunta:
-- ¿Qué edificios hay en el modelo y cuáles son sus alturas y áreas de huella?
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.urban_building_base_mat AS
WITH ground_surfaces AS (
  SELECT
    b.id AS building_id,
    b.objectid AS building_gml_id,
    ST_ZMin(b.envelope) AS ground_elevation,
    ST_ZMax(b.envelope) AS roof_elevation,
    ST_ZMax(b.envelope) - ST_ZMin(b.envelope) AS height_m,
    ST_Multi(
      ST_CollectionExtract(
        ST_MakeValid(
          ST_UnaryUnion(
            ST_Collect(
              ST_Force2D(gd.geometry)
            )
          )
        ),
        3
      )
    )::geometry(MultiPolygon, 4326) AS geom
  FROM citydb.feature b
  JOIN citydb.objectclass oc_b
    ON oc_b.id = b.objectclass_id
   AND oc_b.classname = 'Building'
  JOIN citydb.property p_bound
    ON p_bound.feature_id = b.id
   AND p_bound.name = 'boundary'
  JOIN citydb.feature gs
    ON gs.id = p_bound.val_feature_id
  JOIN citydb.objectclass oc_gs
    ON oc_gs.id = gs.objectclass_id
   AND oc_gs.classname = 'GroundSurface'
  JOIN citydb.property p_geom
    ON p_geom.feature_id = gs.id
   AND p_geom.val_geometry_id IS NOT NULL
  JOIN citydb.geometry_data gd
    ON gd.id = p_geom.val_geometry_id
  GROUP BY b.id, b.objectid, b.envelope
),
metrics AS (
  SELECT
    building_id,
    building_gml_id,
    ground_elevation,
    roof_elevation,
    height_m,
    geom,
    ST_Envelope(ST_Transform(geom, 3879)) AS bbox_3879,
    ST_Area(ST_Transform(geom, 3879)) AS footprint_area_m2
  FROM ground_surfaces
  WHERE geom IS NOT NULL
    AND NOT ST_IsEmpty(geom)
)
SELECT
  row_number() OVER (ORDER BY building_id)::integer AS gid,
  building_id,
  building_gml_id,
  ROUND(ground_elevation::numeric, 2) AS ground_elevation_m,
  ROUND(roof_elevation::numeric, 2) AS roof_elevation_m,
  ROUND(height_m::numeric, 2) AS height_m,

  CASE
    WHEN height_m >= 40 THEN 'muy_alto'
    WHEN height_m >= 25 THEN 'alto'
    WHEN height_m >= 12 THEN 'medio'
    ELSE 'bajo'
  END AS height_category,

  ROUND(footprint_area_m2::numeric, 2) AS footprint_area_m2,
  ROUND(ST_Area(bbox_3879)::numeric, 2) AS bbox_area_m2,

  ROUND(
    LEAST(
      ST_XMax(bbox_3879) - ST_XMin(bbox_3879),
      ST_YMax(bbox_3879) - ST_YMin(bbox_3879)
    )::numeric,
    2
  ) AS min_face_width_m,

  geom
FROM metrics;

CREATE UNIQUE INDEX urban_building_base_mat_gid_idx
ON analysis.urban_building_base_mat (gid);

CREATE INDEX urban_building_base_mat_geom_idx
ON analysis.urban_building_base_mat
USING gist (geom);

CREATE INDEX urban_building_base_mat_geom_3879_idx
ON analysis.urban_building_base_mat
USING gist (ST_Transform(geom, 3879));

-- =============================================================================
-- 1) REGLA: separación entre edificios
--
-- Pregunta:
-- ¿Qué edificios están demasiado cerca entre sí?
--
-- Criterio:
-- < 3 m  = FAIL
-- 3-6 m  = WARN
-- >= 6 m = OK
--
-- Geometría:
-- Línea entre centroides de edificios cercanos.
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule1_building_spacing_mat AS
SELECT
  row_number() OVER (ORDER BY distance_m, building_a_id, building_b_id)::integer AS gid,
  *
FROM (
  SELECT
    a.building_id AS building_a_id,
    b.building_id AS building_b_id,
    a.building_gml_id AS building_a_gml_id,
    b.building_gml_id AS building_b_gml_id,

    ROUND(
      ST_Distance(
        ST_Transform(a.geom, 3879),
        ST_Transform(b.geom, 3879)
      )::numeric,
      2
    ) AS distance_m,

    CASE
      WHEN ST_Distance(ST_Transform(a.geom, 3879), ST_Transform(b.geom, 3879)) < 3
        THEN 'FAIL'
      WHEN ST_Distance(ST_Transform(a.geom, 3879), ST_Transform(b.geom, 3879)) < 6
        THEN 'WARN'
      ELSE 'OK'
    END AS status,

    '¿Qué edificios están demasiado cerca entre sí?'::text AS question,

    ST_MakeLine(
      ST_PointOnSurface(a.geom),
      ST_PointOnSurface(b.geom)
    )::geometry(LineString, 4326) AS geom

  FROM analysis.urban_building_base_mat a
  JOIN analysis.urban_building_base_mat b
    ON b.building_id > a.building_id
  WHERE ST_DWithin(
    ST_Transform(a.geom, 3879),
    ST_Transform(b.geom, 3879),
    6
  )
) q;

CREATE UNIQUE INDEX rule1_building_spacing_mat_gid_idx
ON analysis.rule1_building_spacing_mat (gid);

CREATE INDEX rule1_building_spacing_mat_geom_idx
ON analysis.rule1_building_spacing_mat
USING gist (geom);

-- =============================================================================
-- 2) REGLA: relación altura / ancho
--
-- Pregunta:
-- ¿Qué edificios son altos en relación con su dimensión horizontal mínima?
--
-- Criterio:
-- height / min_face_width > 1.5 = FAIL
-- height / min_face_width > 1.2 = WARN
-- resto = OK
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule2_height_ratio_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  height_m,
  min_face_width_m,
  ROUND((height_m / NULLIF(min_face_width_m, 0))::numeric, 3) AS height_to_width_ratio,

  CASE
    WHEN height_m / NULLIF(min_face_width_m, 0) > 1.5 THEN 'FAIL'
    WHEN height_m / NULLIF(min_face_width_m, 0) > 1.2 THEN 'WARN'
    ELSE 'OK'
  END AS status,

  '¿Qué edificios son altos respecto a su ancho mínimo?'::text AS question,

  geom
FROM analysis.urban_building_base_mat;

CREATE UNIQUE INDEX rule2_height_ratio_mat_gid_idx
ON analysis.rule2_height_ratio_mat (gid);

CREATE INDEX rule2_height_ratio_mat_geom_idx
ON analysis.rule2_height_ratio_mat
USING gist (geom);

-- =============================================================================
-- 3) REGLA: cobertura de suelo
--
-- Pregunta:
-- ¿Qué edificios ocupan demasiada superficie respecto a su área aproximada?
--
-- Sin parcelas reales, se usa el bounding box del edificio como proxy.
--
-- Criterio:
-- cobertura > 60% = FAIL
-- cobertura > 50% = WARN
-- resto = OK
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule3_coverage_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  footprint_area_m2,
  bbox_area_m2,

  ROUND((footprint_area_m2 / NULLIF(bbox_area_m2, 0) * 100)::numeric, 1) AS coverage_pct,

  CASE
    WHEN footprint_area_m2 / NULLIF(bbox_area_m2, 0) > 0.60 THEN 'FAIL'
    WHEN footprint_area_m2 / NULLIF(bbox_area_m2, 0) > 0.50 THEN 'WARN'
    ELSE 'OK'
  END AS status,

  '¿Qué edificios ocupan demasiada superficie respecto a su área aproximada?'::text AS question,

  geom
FROM analysis.urban_building_base_mat;

CREATE UNIQUE INDEX rule3_coverage_mat_gid_idx
ON analysis.rule3_coverage_mat (gid);

CREATE INDEX rule3_coverage_mat_geom_idx
ON analysis.rule3_coverage_mat
USING gist (geom);

-- =============================================================================
-- 4) REGLA: altura mínima
--
-- Pregunta:
-- ¿Hay edificios demasiado bajos que podrían ser estructuras menores?
--
-- Criterio:
-- altura < 3 m = FAIL
-- altura < 5 m = WARN
-- resto = OK
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule4_min_height_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  height_m,

  CASE
    WHEN height_m < 3 THEN 'FAIL'
    WHEN height_m < 5 THEN 'WARN'
    ELSE 'OK'
  END AS status,

  '¿Hay edificios demasiado bajos?'::text AS question,

  geom
FROM analysis.urban_building_base_mat;

CREATE UNIQUE INDEX rule4_min_height_mat_gid_idx
ON analysis.rule4_min_height_mat (gid);

CREATE INDEX rule4_min_height_mat_geom_idx
ON analysis.rule4_min_height_mat
USING gist (geom);

-- =============================================================================
-- 5) REGLA: altura máxima
--
-- Pregunta:
-- ¿Qué edificios superan una altura máxima definida para el análisis?
--
-- Criterio:
-- altura > 50 m = FAIL
-- altura > 40 m = WARN
-- resto = OK
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule5_max_height_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  height_m,

  CASE
    WHEN height_m > 50 THEN 'FAIL'
    WHEN height_m > 40 THEN 'WARN'
    ELSE 'OK'
  END AS status,

  '¿Qué edificios superan la altura máxima definida?'::text AS question,

  geom
FROM analysis.urban_building_base_mat;

CREATE UNIQUE INDEX rule5_max_height_mat_gid_idx
ON analysis.rule5_max_height_mat (gid);

CREATE INDEX rule5_max_height_mat_geom_idx
ON analysis.rule5_max_height_mat
USING gist (geom);

-- =============================================================================
-- 6) REGLA: densidad / FAR aproximado
--
-- Pregunta:
-- ¿Qué edificios tienen mayor densidad estimada según su altura y huella?
--
-- Estimación:
-- pisos = max(1, round(height / 3.2))
-- FAR aprox = (huella * pisos) / bbox_area
--
-- Criterio:
-- FAR > 3.0 = FAIL
-- FAR > 2.5 = WARN
-- resto = OK
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.rule6_far_mat AS
SELECT
  gid,
  building_id,
  building_gml_id,
  height_m,
  footprint_area_m2,
  bbox_area_m2,

  GREATEST(1, ROUND(height_m / 3.2)::integer) AS estimated_floors,

  ROUND(
    (footprint_area_m2 * GREATEST(1, ROUND(height_m / 3.2)::integer))::numeric,
    2
  ) AS estimated_total_floor_area_m2,

  ROUND(
    (
      footprint_area_m2 * GREATEST(1, ROUND(height_m / 3.2)::integer)
      / NULLIF(bbox_area_m2, 0)
    )::numeric,
    3
  ) AS far_ratio,

  CASE
    WHEN (
      footprint_area_m2 * GREATEST(1, ROUND(height_m / 3.2)::integer)
      / NULLIF(bbox_area_m2, 0)
    ) > 3.0 THEN 'FAIL'
    WHEN (
      footprint_area_m2 * GREATEST(1, ROUND(height_m / 3.2)::integer)
      / NULLIF(bbox_area_m2, 0)
    ) > 2.5 THEN 'WARN'
    ELSE 'OK'
  END AS status,

  '¿Qué edificios tienen mayor densidad estimada?'::text AS question,

  geom
FROM analysis.urban_building_base_mat;

CREATE UNIQUE INDEX rule6_far_mat_gid_idx
ON analysis.rule6_far_mat (gid);

CREATE INDEX rule6_far_mat_geom_idx
ON analysis.rule6_far_mat
USING gist (geom);

-- =============================================================================
-- 7) RESULTADO COMBINADO
--
-- Pregunta:
-- ¿Qué edificios concentran más alertas urbanas según varias reglas a la vez?
--
-- Score:
-- FAIL = 2 puntos
-- WARN = 1 punto
-- OK   = 0 puntos
-- =============================================================================

CREATE MATERIALIZED VIEW analysis.combined_urban_rules_mat AS
WITH nearest_neighbor AS (
  SELECT
    a.building_id,
    MIN(
      ST_Distance(
        ST_Transform(a.geom, 3879),
        ST_Transform(b.geom, 3879)
      )
    ) AS nearest_building_m
  FROM analysis.urban_building_base_mat a
  JOIN analysis.urban_building_base_mat b
    ON b.building_id <> a.building_id
  GROUP BY a.building_id
),
rules AS (
  SELECT
    b.gid,
    b.building_id,
    b.building_gml_id,
    b.height_m,
    b.height_category,
    b.footprint_area_m2,
    b.bbox_area_m2,
    b.min_face_width_m,

    ROUND(n.nearest_building_m::numeric, 2) AS nearest_building_m,
    ROUND((b.height_m / NULLIF(b.min_face_width_m, 0))::numeric, 3) AS height_to_width_ratio,
    ROUND((b.footprint_area_m2 / NULLIF(b.bbox_area_m2, 0) * 100)::numeric, 1) AS coverage_pct,

    GREATEST(1, ROUND(b.height_m / 3.2)::integer) AS estimated_floors,

    ROUND(
      (
        b.footprint_area_m2 * GREATEST(1, ROUND(b.height_m / 3.2)::integer)
        / NULLIF(b.bbox_area_m2, 0)
      )::numeric,
      3
    ) AS far_ratio,

    CASE
      WHEN n.nearest_building_m < 3 THEN 'FAIL'
      WHEN n.nearest_building_m < 6 THEN 'WARN'
      ELSE 'OK'
    END AS rule1_spacing,

    CASE
      WHEN b.height_m / NULLIF(b.min_face_width_m, 0) > 1.5 THEN 'FAIL'
      WHEN b.height_m / NULLIF(b.min_face_width_m, 0) > 1.2 THEN 'WARN'
      ELSE 'OK'
    END AS rule2_height_ratio,

    CASE
      WHEN b.footprint_area_m2 / NULLIF(b.bbox_area_m2, 0) > 0.60 THEN 'FAIL'
      WHEN b.footprint_area_m2 / NULLIF(b.bbox_area_m2, 0) > 0.50 THEN 'WARN'
      ELSE 'OK'
    END AS rule3_coverage,

    CASE
      WHEN b.height_m < 3 THEN 'FAIL'
      WHEN b.height_m < 5 THEN 'WARN'
      ELSE 'OK'
    END AS rule4_min_height,

    CASE
      WHEN b.height_m > 50 THEN 'FAIL'
      WHEN b.height_m > 40 THEN 'WARN'
      ELSE 'OK'
    END AS rule5_max_height,

    CASE
      WHEN (
        b.footprint_area_m2 * GREATEST(1, ROUND(b.height_m / 3.2)::integer)
        / NULLIF(b.bbox_area_m2, 0)
      ) > 3.0 THEN 'FAIL'
      WHEN (
        b.footprint_area_m2 * GREATEST(1, ROUND(b.height_m / 3.2)::integer)
        / NULLIF(b.bbox_area_m2, 0)
      ) > 2.5 THEN 'WARN'
      ELSE 'OK'
    END AS rule6_far,

    b.geom
  FROM analysis.urban_building_base_mat b
  LEFT JOIN nearest_neighbor n
    ON n.building_id = b.building_id
),
scored AS (
  SELECT
    *,
    (
      CASE WHEN rule1_spacing = 'FAIL' THEN 2 WHEN rule1_spacing = 'WARN' THEN 1 ELSE 0 END +
      CASE WHEN rule2_height_ratio = 'FAIL' THEN 2 WHEN rule2_height_ratio = 'WARN' THEN 1 ELSE 0 END +
      CASE WHEN rule3_coverage = 'FAIL' THEN 2 WHEN rule3_coverage = 'WARN' THEN 1 ELSE 0 END +
      CASE WHEN rule4_min_height = 'FAIL' THEN 2 WHEN rule4_min_height = 'WARN' THEN 1 ELSE 0 END +
      CASE WHEN rule5_max_height = 'FAIL' THEN 2 WHEN rule5_max_height = 'WARN' THEN 1 ELSE 0 END +
      CASE WHEN rule6_far = 'FAIL' THEN 2 WHEN rule6_far = 'WARN' THEN 1 ELSE 0 END
    ) AS risk_score
  FROM rules
)
SELECT
  gid,
  building_id,
  building_gml_id,
  height_m,
  height_category,
  footprint_area_m2,
  bbox_area_m2,
  min_face_width_m,
  nearest_building_m,
  height_to_width_ratio,
  coverage_pct,
  estimated_floors,
  far_ratio,
  rule1_spacing,
  rule2_height_ratio,
  rule3_coverage,
  rule4_min_height,
  rule5_max_height,
  rule6_far,
  risk_score,

  CASE
    WHEN risk_score >= 5 THEN 'HIGH'
    WHEN risk_score >= 3 THEN 'MEDIUM'
    WHEN risk_score >= 1 THEN 'LOW'
    ELSE 'OK'
  END AS risk_level,

  '¿Qué edificios concentran más alertas urbanas según varias reglas?'::text AS question,

  geom
FROM scored;

CREATE UNIQUE INDEX combined_urban_rules_mat_gid_idx
ON analysis.combined_urban_rules_mat (gid);

CREATE INDEX combined_urban_rules_mat_geom_idx
ON analysis.combined_urban_rules_mat
USING gist (geom);

-- =============================================================================
-- 8) RESUMEN SIN GEOMETRÍA
-- Esta vista no se publica como capa espacial; sirve para revisar resultados.
-- =============================================================================

DROP VIEW IF EXISTS analysis.urban_rules_summary;

CREATE VIEW analysis.urban_rules_summary AS
SELECT
  COUNT(*) AS total_buildings,
  COUNT(*) FILTER (WHERE risk_level = 'HIGH') AS high_risk,
  COUNT(*) FILTER (WHERE risk_level = 'MEDIUM') AS medium_risk,
  COUNT(*) FILTER (WHERE risk_level = 'LOW') AS low_risk,
  COUNT(*) FILTER (WHERE risk_level = 'OK') AS ok_buildings,
  ROUND(AVG(height_m)::numeric, 2) AS avg_height_m,
  ROUND(MAX(height_m)::numeric, 2) AS max_height_m,
  ROUND(AVG(risk_score)::numeric, 2) AS avg_risk_score
FROM analysis.combined_urban_rules_mat;

-- =============================================================================
-- FIN
-- =============================================================================
