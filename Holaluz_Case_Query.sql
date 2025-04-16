-- #####################################################
-- EJERCICIO 1: ANÁLISIS DE CLIENTES Y CONSUMOS
-- #####################################################

-- 1A. Número de clientes por producto (excluyendo los que tienen instalación solar)
SELECT 
    e.product, 
    COUNT(DISTINCT e.client_id) AS total_clientes
FROM HolaluzCase.dbo.con_econtract_dim$ e
LEFT JOIN HolaluzCase.dbo.con_scontract_dim$ s 
    ON e.client_id = s.client_id
WHERE s.client_id IS NULL
GROUP BY e.product
ORDER BY total_clientes DESC;

---------------------------------------------------------

-- 1B. Edad promedio de los contratos (en años), separando con y sin solar
SELECT 
    CASE 
        WHEN s.client_id IS NOT NULL THEN 'Con Solar'
        ELSE 'Sin Solar'
    END AS tipo_cliente,
    AVG(DATEDIFF(YEAR, e.supply_start_date, GETDATE())) AS antiguedad_promedio_anios
FROM HolaluzCase.dbo.con_econtract_dim$ e
LEFT JOIN HolaluzCase.dbo.con_scontract_dim$ s 
    ON e.client_id = s.client_id
WHERE e.supply_start_date IS NOT NULL
GROUP BY 
    CASE 
        WHEN s.client_id IS NOT NULL THEN 'Con Solar'
        ELSE 'Sin Solar'
    END;

---------------------------------------------------------

-- 1C. Crear tabla con clientes que superan en más de 30% y 300kWh su consumo estimado
DROP TABLE IF EXISTS HolaluzCase.dbo.Clientes_Exceso_Consumo;

WITH ConsumoCliente AS (
    SELECT 
        e.client_id,
        SUM(c.real_consumption) AS consumo_total,
        SUM(e.forecasted_consumption) AS consumo_esperado,
        SUM(c.real_consumption) - SUM(e.forecasted_consumption) AS desviacion
    FROM HolaluzCase.dbo.con_econtract_dim$ e
    JOIN HolaluzCase.dbo.ene_consumption_2024$ c 
        ON e.contract_id = c.contract_id
    GROUP BY e.client_id
)
SELECT 
    client_id,
    consumo_total,
    consumo_esperado,
    desviacion
INTO HolaluzCase.dbo.Clientes_Exceso_Consumo
FROM ConsumoCliente
WHERE consumo_total > (consumo_esperado * 1.3)
  AND desviacion >= 300;

---------------------------------------------------------

-- 1D. Pérdidas económicas de clientes que sobreconsumen
SELECT 
    SUM(ISNULL(c.real_consumption, 0) - ISNULL(e.forecasted_consumption, 0)) * 0.12 AS perdidas_totales_euros
FROM HolaluzCase.dbo.con_econtract_dim$ e
JOIN HolaluzCase.dbo.ene_consumption_2024$ c 
    ON e.contract_id = c.contract_id
JOIN HolaluzCase.dbo.Clientes_Exceso_Consumo clientes
    ON e.client_id = clientes.client_id
WHERE ISNULL(c.real_consumption, 0) > ISNULL(e.forecasted_consumption, 0);

---------------------------------------------------------

-- 1E. Desviación promedio con y sin solar
WITH ConsumoDesviacion AS (
    SELECT 
        e.client_id,
        SUM(ISNULL(c.real_consumption, 0)) AS consumo_real,
        SUM(ISNULL(e.forecasted_consumption, 0)) AS consumo_esperado,
        SUM(ISNULL(c.real_consumption, 0)) - SUM(ISNULL(e.forecasted_consumption, 0)) AS desviacion
    FROM HolaluzCase.dbo.con_econtract_dim$ e
    JOIN HolaluzCase.dbo.ene_consumption_2024$ c 
        ON e.contract_id = c.contract_id
    GROUP BY e.client_id
)
SELECT 
    CASE 
        WHEN s.client_id IS NOT NULL THEN 'Con Solar'
        ELSE 'Sin Solar'
    END AS tipo_cliente,
    AVG(desviacion) AS desviacion_promedio_kWh
FROM ConsumoDesviacion d
LEFT JOIN HolaluzCase.dbo.con_scontract_dim$ s
    ON d.client_id = s.client_id
GROUP BY 
    CASE 
        WHEN s.client_id IS NOT NULL THEN 'Con Solar'
        ELSE 'Sin Solar'
    END;

---------------------------------------------------------

-- 1F. Top 5 contratos con mayor impacto en margen, sin NULLs en forecast
SELECT TOP 5
    e.contract_id,
    e.client_id,
    e.forecasted_consumption,
    c.real_consumption,
    (c.real_consumption - e.forecasted_consumption) * 0.12 AS impacto_margen_euros
FROM HolaluzCase.dbo.con_econtract_dim$ e
JOIN HolaluzCase.dbo.ene_consumption_2024$ c 
    ON e.contract_id = c.contract_id
WHERE e.forecasted_consumption IS NOT NULL
  AND c.real_consumption > e.forecasted_consumption
ORDER BY 
    (c.real_consumption - e.forecasted_consumption) * 0.12 DESC;

-- #####################################################
-- EJERCICIO 2: PROCESO KICK-OUT Y CONTROL
-- #####################################################

-- 2A. Crear tabla Kickout_Febrero2025 con los clientes a cambiar de tarifa
DROP TABLE IF EXISTS HolaluzCase.dbo.Kickout_Febrero2025;

SELECT 
    e.contract_id,
    e.client_id,
    e.forecasted_consumption,
    c.real_consumption,
    (c.real_consumption - e.forecasted_consumption) AS desviacion_kwh,
    CAST('202502' AS VARCHAR(6)) AS fecha_envio,
    CASE 
        WHEN s.client_id IS NOT NULL THEN 'C1'
        WHEN c.real_consumption >= (e.forecasted_consumption * 2.0) THEN 'C2'
        ELSE 'C3'
    END AS segmento
INTO HolaluzCase.dbo.Kickout_Febrero2025
FROM HolaluzCase.dbo.con_econtract_dim$ e
JOIN HolaluzCase.dbo.ene_consumption_2024$ c ON e.contract_id = c.contract_id
LEFT JOIN HolaluzCase.dbo.con_scontract_dim$ s ON e.client_id = s.client_id
WHERE c.real_consumption > (e.forecasted_consumption * 1.3)
  AND (c.real_consumption - e.forecasted_consumption) >= 300;

---------------------------------------------------------

-- 2E.1 Crear tabla auxiliar con la distribución mensual de consumo
CREATE TABLE #DistribucionMensual (
    mes CHAR(2),
    porcentaje DECIMAL(5,2)
);

INSERT INTO #DistribucionMensual VALUES
('01', 0.12), ('02', 0.10), ('03', 0.08), ('04', 0.07),
('05', 0.05), ('06', 0.06), ('07', 0.08), ('08', 0.10),
('09', 0.07), ('10', 0.08), ('11', 0.09), ('12', 0.10);

---------------------------------------------------------

-- 2E.2 Consulta para calcular el consumo mensual estimado (ejemplo: febrero)
SELECT 
    k.contract_id,
    k.client_id,
    ISNULL(k.real_consumption, 0) AS consumo_total,
    d.mes,
    ROUND(ISNULL(k.real_consumption, 0) * d.porcentaje, 2) AS consumo_mensual_kWh
FROM HolaluzCase.dbo.Kickout_Febrero2025 k
JOIN #DistribucionMensual d ON d.mes = '02';
























