-- ============================================================
-- ANÁLISIS: EDIFICIOS ALTOS PRÓXIMOS A ESPACIOS VERDES
-- Helsinki 3D / 3DCityDB / PostGIS / QGIS
--
-- Pregunta:
-- ¿Cuántos edificios altos se encuentran próximos a espacios
-- verdes en la zona seleccionada y qué características tienen?
--
-- EPSG:4326 = latitud/longitud, grados
-- EPSG:3879 = sistema métrico local de Helsinki, metros
-- ============================================================


-- ============================================================
-- 0. Crear schema de análisis
-- ============================================================

CREATE SCHEMA IF NOT EXISTS analysis;


-- ============================================================
-- 1. Limpiar resultados anteriores
-- ============================================================

DROP VIEW IF EXISTS analysis.high_buildings_near_green_points CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.buildings_near_green_points_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.green_areas_near_model_mat CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analysis.building_height_points_mat CASCADE;


-- ============================================================
-- 2. Ver qué geometrías existen en el modelo 3D
--
-- Esta consulta es solo de control.
-- Muestra qué clases hay dentro de citydb.mv_geometries.
--
-- Resultado esperado aproximado:
-- Building        200
-- GroundSurface   201
-- RoofSurface    2191
-- WallSurface    6476
-- ============================================================

SELECT
  class,
  COUNT(*) AS total
FROM citydb.mv_geometries
GROUP BY class
ORDER BY COUNT(*) DESC;


-- ============================================================
-- 3. Crear puntos de edificios con altura estimada
--
-- Pregunta que responde:
-- ¿Qué edificios hay en el modelo y qué altura estimada tiene cada uno?
--
-- Se toma solamente la clase Building.
--
-- height_m:
-- Altura estimada del edificio.
-- Se calcula como:
-- Z máxima - Z mínima
--
-- geom:
-- Punto 2D representativo del edificio.
-- Se usa después para calcular distancia al espacio verde más cercano.
-- ============================================================

CREATE MATERIALIZED VIEW analysis.building_height_points_mat AS
SELECT
  row_number() OVER ()::integer AS gid,
  m.id AS source_id,
  m.class AS object_class,

  ROUND(
    (ST_ZMax(Box3D(m.geom)) - ST_ZMin(Box3D(m.geom)))::numeric,
    2
  ) AS height_m,

  CASE
    WHEN ST_ZMax(Box3D(m.geom)) - ST_ZMin(Box3D(m.geom)) >= 40 THEN 'muy_alto'
    WHEN ST_ZMax(Box3D(m.geom)) - ST_ZMin(Box3D(m.geom)) >= 25 THEN 'alto'
    WHEN ST_ZMax(Box3D(m.geom)) - ST_ZMin(Box3D(m.geom)) >= 12 THEN 'medio'
    ELSE 'bajo'
  END AS height_category,

  ST_SetSRID(
    ST_MakePoint(
      (ST_XMin(Box3D(m.geom)) + ST_XMax(Box3D(m.geom))) / 2,
      (ST_YMin(Box3D(m.geom)) + ST_YMax(Box3D(m.geom))) / 2
    ),
    4326
  )::geometry(Point, 4326) AS geom

FROM citydb.mv_geometries m
WHERE m.class = 'Building';


-- Índices para mejorar consultas y visualización

CREATE UNIQUE INDEX building_height_points_mat_gid_idx
ON analysis.building_height_points_mat (gid);

CREATE INDEX building_height_points_mat_geom_idx
ON analysis.building_height_points_mat
USING gist (geom);

CREATE INDEX building_height_points_mat_geom_3879_idx
ON analysis.building_height_points_mat
USING gist (ST_Transform(geom, 3879));


-- ============================================================
-- 4. Verificar edificios generados
-- ============================================================

SELECT
  COUNT(*) AS total_buildings
FROM analysis.building_height_points_mat;


SELECT
  gid,
  source_id,
  height_m,
  height_category
FROM analysis.building_height_points_mat
ORDER BY height_m DESC
LIMIT 20;


-- ============================================================
-- 5. Filtrar espacios verdes cercanos al modelo 3D
--
-- Pregunta que responde:
-- ¿Qué espacios verdes están cerca de la zona del modelo 3D?
--
-- Criterio:
-- Se conserva un espacio verde si existe al menos un edificio
-- del modelo a 500 metros o menos.
--
-- Importante:
-- Aunque la geometría final queda en EPSG:4326,
-- las distancias se calculan en EPSG:3879.
-- ============================================================

CREATE MATERIALIZED VIEW analysis.green_areas_near_model_mat AS
SELECT DISTINCT
  g.gid,

  ST_Multi(
    ST_CollectionExtract(
      ST_MakeValid(g.geom),
      3
    )
  )::geometry(MultiPolygon, 4326) AS geom

FROM analysis.green_areas g
WHERE EXISTS (
  SELECT 1
  FROM analysis.building_height_points_mat b
  WHERE ST_DWithin(
    ST_Transform(g.geom, 3879),
    ST_Transform(b.geom, 3879),
    500
  )
);


-- Índices

CREATE INDEX green_areas_near_model_mat_geom_idx
ON analysis.green_areas_near_model_mat
USING gist (geom);

CREATE INDEX green_areas_near_model_mat_geom_3879_idx
ON analysis.green_areas_near_model_mat
USING gist (ST_Transform(geom, 3879));


-- ============================================================
-- 6. Verificar espacios verdes cercanos
-- ============================================================

SELECT
  COUNT(*) AS green_areas_near_model
FROM analysis.green_areas_near_model_mat;


-- ============================================================
-- 7. Calcular distancia de cada edificio al espacio verde más cercano
--
-- Pregunta que responde:
-- ¿Cuál es el espacio verde más cercano a cada edificio y a qué distancia está?
--
-- JOIN LATERAL:
-- Permite buscar el espacio verde más cercano para cada edificio.
--
-- ORDER BY geom <-> geom:
-- Ordena por cercanía espacial.
-- ============================================================

CREATE MATERIALIZED VIEW analysis.buildings_near_green_points_mat AS
SELECT
  b.gid,
  b.source_id,
  b.object_class,
  b.height_m,
  b.height_category,

  nearest_green.gid AS green_id,

  ROUND(
    ST_Distance(
      ST_Transform(b.geom, 3879),
      ST_Transform(nearest_green.geom, 3879)
    )::numeric,
    2
  ) AS distance_to_green_m,

  b.geom

FROM analysis.building_height_points_mat b
JOIN LATERAL (
  SELECT
  g.gid,
    g.geom
  FROM analysis.green_areas_near_model_mat g
  ORDER BY
    ST_Transform(b.geom, 3879)
    <->
    ST_Transform(g.geom, 3879)
  LIMIT 1
) nearest_green ON true;


-- Índices

CREATE UNIQUE INDEX buildings_near_green_points_mat_gid_idx
ON analysis.buildings_near_green_points_mat (gid);

CREATE INDEX buildings_near_green_points_mat_geom_idx
ON analysis.buildings_near_green_points_mat
USING gist (geom);

CREATE INDEX buildings_near_green_points_mat_geom_3879_idx
ON analysis.buildings_near_green_points_mat
USING gist (ST_Transform(geom, 3879));


-- ============================================================
-- 8. Verificar distancia al espacio verde más cercano
-- ============================================================

SELECT
  source_id,
  height_m,
  height_category,
  green_id,
  distance_to_green_m
FROM analysis.buildings_near_green_points_mat
ORDER BY height_m DESC
LIMIT 20;


-- ============================================================
-- 9. Crear vista final:
-- Edificios altos próximos a espacios verdes
--
-- Pregunta que responde:
-- ¿Cuántos edificios altos están a 100 metros o menos
-- de un espacio verde?
--
-- Criterio:
-- Edificio alto: height_m >= 25
-- Próximo a verde: distance_to_green_m <= 100
-- ============================================================

CREATE OR REPLACE VIEW analysis.high_buildings_near_green_points AS
SELECT
  gid,
  source_id,
  object_class,
  height_m,
  height_category,
  green_id,
  distance_to_green_m,
  geom
FROM analysis.buildings_near_green_points_mat
WHERE height_m >= 25
  AND distance_to_green_m <= 100;


-- ============================================================
-- 10. Resultado final
-- ============================================================

SELECT
  COUNT(*) AS high_buildings_near_green
FROM analysis.high_buildings_near_green_points;


-- ============================================================
-- 11. Resumen estadístico final
-- ============================================================

SELECT
  COUNT(*) AS high_buildings_near_green,
  ROUND(AVG(height_m)::numeric, 2) AS avg_height_m,
  ROUND(MIN(height_m)::numeric, 2) AS min_height_m,
  ROUND(MAX(height_m)::numeric, 2) AS max_height_m,
  ROUND(AVG(distance_to_green_m)::numeric, 2) AS avg_distance_to_green_m,
  ROUND(MIN(distance_to_green_m)::numeric, 2) AS min_distance_to_green_m,
  ROUND(MAX(distance_to_green_m)::numeric, 2) AS max_distance_to_green_m
FROM analysis.high_buildings_near_green_points;


-- ============================================================
-- 12. Resumen por categoría de altura
-- ============================================================

SELECT
  height_category,
  COUNT(*) AS buildings,
  ROUND(AVG(height_m)::numeric, 2) AS avg_height_m,
  ROUND(AVG(distance_to_green_m)::numeric, 2) AS avg_distance_to_green_m
FROM analysis.high_buildings_near_green_points
GROUP BY height_category
ORDER BY avg_height_m DESC;


-- ============================================================
-- 13. Ver todas las capas creadas en analysis
-- ============================================================

SELECT
  table_schema,
  table_name
FROM information_schema.tables
WHERE table_schema = 'analysis'
ORDER BY table_name;


-- ============================================================
-- 14. Colores sugeridos para QGIS / GeoServer
-- ============================================================
--
-- height_category:
--
-- muy_alto  → rojo      #e74c3c
-- alto      → naranja   #f39c12
-- medio     → azul      #3498db
-- bajo      → gris      #95a5a6
--
-- Capa final high_buildings_near_green_points:
-- puede mostrarse toda en rojo o categorizada por height_category.
-- ============================================================