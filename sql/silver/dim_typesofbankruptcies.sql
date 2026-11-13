CREATE OR REPLACE VIEW silver.dim_typesofbankruptcies
AS 
SELECT
    TRIM(key)               AS type_key,
    title                   AS type_title, 
    description             AS type_description
FROM bronze.raw_typeofbankruptcy;