/* ============================================================
   ASTHMA FEATURE MATRIX (1 row per patient)
   - Index date: first asthma diagnosis date
   - Lookback: 365d before index date
   - Outcome: exacerbation dx in 365d after index date
   ============================================================ */

WITH

/* 1) Identify asthma dx rows (ICD9 493.*, ICD10 J45.*) */
asthma_dx_rows AS (
    SELECT
        dp.PatientID,
        CAST(COALESCE(dp.StartDate, ef.EncounterContactDate) AS DATE) AS dx_date,
        dc.DiagnosisCode,
        dc.DiagnosisName
    FROM rpt.CDM_DiagnosisProblemFact dp
    LEFT JOIN rpt.CDM_EncounterFact ef
        ON ef.PatientEncounterCSNID = dp.PatientEncounterCSNID
    JOIN rpt.DIM_DiagnosisCodeDim dc
        ON dp.DiagnosisID = dc.DiagnosisID
    WHERE dp.PatientID IS NOT NULL
      AND (
            dc.DiagnosisCode LIKE 'J45%'
         OR dc.DiagnosisCode LIKE '493%'
            /* removed diagnosisName like asthma */
      )
      AND COALESCE(dp.StartDate, ef.EncounterContactDate) IS NOT NULL
),

/* 2) Index date per patient = first asthma dx date */
index_table AS (
    SELECT
        PatientID,
        MIN(dx_date) AS index_date
    FROM asthma_dx_rows
    GROUP BY PatientID
),

/* 3) Window dates: lookback + prediction horizon */
windowed_patients AS (
    SELECT
        PatientID,
        index_date,
        DATEADD(DAY, -365, index_date) AS lb_start_date,
        index_date AS lb_end_date,
        DATEADD(DAY, 365, index_date) AS fu_end_date
    FROM index_table
),

/* 4) Demographics */
demographics AS (
    SELECT
        w.PatientID,
        MAX(pd.Sex) AS Sex,
        MAX(pd.FirstRace) AS FirstRace,
        MAX(pd.Ethnicity) AS Ethnicity,
        MAX(pd.SmokingStatus) AS SmokingStatus,
        MAX(pd.BirthDate) AS BirthDate
    FROM windowed_patients w
    LEFT JOIN rpt.DIM_PatientDim pd
        ON pd.PatientID = w.PatientID
    GROUP BY w.PatientID
),

/* 5) Encounters in lookback (utilization features) */
encounters_lb AS (
    SELECT
        w.PatientID,

        COUNT(*) AS lb_total_encounters,

        SUM(CASE WHEN ef.IsEDVisit = 1 THEN 1 ELSE 0 END)
            AS lb_ed_visits,

        SUM(CASE WHEN ef.IsInpatient = 1 THEN 1 ELSE 0 END)
            AS lb_inpatient_encounters

    FROM windowed_patients w
    LEFT JOIN rpt.CDM_EncounterFact ef
        ON ef.PatientID = w.PatientID
       AND CAST(ef.EncounterContactDate AS DATE) >= w.lb_start_date
       AND CAST(ef.EncounterContactDate AS DATE) < w.lb_end_date

    GROUP BY w.PatientID
),

/* 6) Comorbidities in lookback via diagnosis codes
      (allergic rhinitis 477*/J30*, obesity 278*/E66*)
      FIXED: patient-specific lookback window */
comorbid_dx_lb AS (
    SELECT
        w.PatientID,

        /* added icd10 codes */
        MAX(
            CASE
                WHEN dc.DiagnosisCode LIKE '477%'
                  OR dc.DiagnosisCode LIKE 'J30%'
                THEN 1 ELSE 0
            END
        ) AS lb_allergic_rhinitis_flag,

        MAX(
            CASE
                WHEN dc.DiagnosisCode LIKE '278%'
                  OR dc.DiagnosisCode LIKE 'E66%'
                THEN 1 ELSE 0
            END
        ) AS lb_obesity_flag

    FROM windowed_patients w

    LEFT JOIN rpt.CDM_DiagnosisProblemFact dp
        ON dp.PatientID = w.PatientID

    LEFT JOIN rpt.CDM_EncounterFact ef
        ON ef.PatientEncounterCSNID = dp.PatientEncounterCSNID

    LEFT JOIN rpt.DIM_DiagnosisCodeDim dc
        ON dp.DiagnosisID = dc.DiagnosisID

    WHERE dp.PatientID IS NOT NULL
      AND COALESCE(dp.StartDate, ef.EncounterContactDate) IS NOT NULL
      AND CAST(COALESCE(dp.StartDate, ef.EncounterContactDate) AS DATE)
            >= w.lb_start_date
      AND CAST(COALESCE(dp.StartDate, ef.EncounterContactDate) AS DATE)
            < w.lb_end_date

    GROUP BY w.PatientID
),

/* 7) AllergyFact features
      (using StartDate/EndDate overlap with lookback window) */
allergy_lb AS (
    SELECT
        w.PatientID,

        COUNT(af.ProblemListID) AS lb_allergy_count,

        MAX(
            CASE
                WHEN af.ProblemListID IS NOT NULL THEN 1
                ELSE 0
            END
        ) AS lb_any_allergy_record

    FROM windowed_patients w

    LEFT JOIN rpt.CDM_AllergyFact af
        ON af.PatientID = w.PatientID
       AND CAST(af.StartDate AS DATE) < w.lb_end_date
       AND (
            af.EndDate IS NULL
            OR CAST(af.EndDate AS DATE) >= w.lb_start_date
       )

    GROUP BY w.PatientID
),

/* 8) Medication orders in lookback */
med_orders_lb_raw AS (
    SELECT
        w.PatientID,

        COALESCE(mof.OrderDateTime, mof.OrderStartDate)
            AS med_datetime,

        md.MedicationName,
        md.GenericName,
        mof.AsNeededFlag

    FROM windowed_patients w

    LEFT JOIN rpt.CDM_MedicationOrderFact mof
        ON mof.PatientID = w.PatientID
       AND CAST(COALESCE(mof.OrderDateTime, mof.OrderStartDate) AS DATE)
            >= w.lb_start_date
       AND CAST(COALESCE(mof.OrderDateTime, mof.OrderStartDate) AS DATE)
            < w.lb_end_date

    LEFT JOIN rpt.DIM_MedicationDim md
        ON md.MedicationID = mof.MedicationID

    WHERE mof.PatientID IS NOT NULL
),

/* 9) Medication category flags per order */
med_orders_lb_tagged AS (
    SELECT
        PatientID,

        CASE
            WHEN AsNeededFlag = 'Y' THEN 1
            ELSE 0
        END AS is_prn,

        /* SABA */
        CASE
            WHEN LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%albuterol%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%levalbuterol%'
            THEN 1 ELSE 0
        END AS is_saba,

        /* ICS (single-agent) */
        CASE
            WHEN LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%fluticasone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%budesonide%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%beclomethasone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%mometasone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%ciclesonide%'
            THEN 1 ELSE 0
        END AS is_ics,

        /* ICS/LABA combos */
        CASE
            WHEN LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%salmeterol%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%formoterol%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%vilanterol%'
            THEN 1 ELSE 0
        END AS is_laba_component,

        /* Montelukast */
        CASE
            WHEN LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%montelukast%'
            THEN 1 ELSE 0
        END AS is_montelukast,

        /* Oral/systemic steroids */
        CASE
            WHEN LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%prednisone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%prednisolone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%methylprednisolone%'
              OR LOWER(COALESCE(GenericName, MedicationName))
                    LIKE '%dexamethasone%'
            THEN 1 ELSE 0
        END AS is_oral_steroid

    FROM med_orders_lb_raw
),

/* 10) Aggregate medication features per patient */
med_features_lb AS (
    SELECT
        PatientID,

        SUM(CASE WHEN is_saba = 1 THEN 1 ELSE 0 END)
            AS lb_saba_orders,

        SUM(
            CASE
                WHEN is_saba = 1
                 AND is_prn = 1
                THEN 1 ELSE 0
            END
        ) AS lb_saba_prn_orders,

        /* ICS alone */
        SUM(
            CASE
                WHEN is_ics = 1
                 AND is_laba_component = 0
                THEN 1 ELSE 0
            END
        ) AS lb_ics_orders,

        /* ICS/LABA */
        SUM(
            CASE
                WHEN is_ics = 1
                 AND is_laba_component = 1
                THEN 1 ELSE 0
            END
        ) AS lb_ics_laba_orders,

        SUM(
            CASE
                WHEN is_montelukast = 1
                THEN 1 ELSE 0
            END
        ) AS lb_montelukast_orders,

        SUM(
            CASE
                WHEN is_oral_steroid = 1
                THEN 1 ELSE 0
            END
        ) AS lb_oral_steroid_orders

    FROM med_orders_lb_tagged
    GROUP BY PatientID
),

/* 11) Biomarkers tagged from LabOrderResultFact (values) */
lab_tagged AS (
    SELECT
        w.PatientID,

        lrf.ResultDateTime,
        lrf.OrderResultNumericValue,
        lrf.ReferenceUnit,
        lcd.ComponentName,

        CASE

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%eosinophil%percent%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%eosinophil %%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%eosinophils relative%'
                 )
             AND LOWER(lcd.ComponentName) NOT LIKE '%abs%'
            THEN 'eos_pct'

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%absolute eosinophil%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%eosinophils absolute%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%eosinophil #%'
                 )
            THEN 'eos_abs'

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%immunoglobulin e%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%total ige%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%ige total%'
                 )
            THEN 'ige_total'

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%c reactive protein%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%crp%'
                 )
            THEN 'crp'

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%neutrophil abs%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%absolute neutrophil%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%neutrophils absolute%'
                 )
            THEN 'neut_abs'

            WHEN (
                    LOWER(lcd.ComponentName)
                        LIKE '%exhaled nitric oxide%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%fractional exhaled nitric oxide%'
                 OR LOWER(lcd.ComponentName)
                        LIKE '%feno%'
                 )
            THEN 'feno'

            ELSE NULL
        END AS biomarker

    FROM windowed_patients w

    JOIN rpt.CDM_LabOrderResultFact lrf
        ON lrf.PatientID = w.PatientID
       AND lrf.OrderResultNumericValue IS NOT NULL
       AND lrf.ResultDateTime IS NOT NULL
       AND CAST(lrf.ResultDateTime AS DATE) < w.index_date
       AND CAST(lrf.ResultDateTime AS DATE) >= w.lb_start_date

    JOIN rpt.DIM_LabComponentDim lcd
        ON lrf.CBD_LabComponentKey = lcd.LabComponentKey
),

/* 12) Rank most recent lab per patient/biomarker (pre-index) */
lab_ranked AS (
    SELECT
        PatientID,
        biomarker,
        ResultDateTime,

        CASE
            WHEN biomarker = 'neut_abs'
             AND ReferenceUnit IS NOT NULL
             AND LOWER(ReferenceUnit) LIKE 'cells/%'
            THEN OrderResultNumericValue / 1000.0

            ELSE OrderResultNumericValue
        END AS value_num,

        ROW_NUMBER() OVER (
            PARTITION BY PatientID, biomarker
            ORDER BY ResultDateTime DESC
        ) AS rn

    FROM lab_tagged
    WHERE biomarker IS NOT NULL
),

/* 13) Pivot biomarker values + dates into columns */
lab_features AS (
    SELECT
        PatientID,

        MAX(CASE WHEN biomarker = 'eos_pct'
                  AND rn = 1
                 THEN value_num END)
            AS eos_pct_recent,

        MAX(CASE WHEN biomarker = 'eos_abs'
                  AND rn = 1
                 THEN value_num END)
            AS eos_abs_recent,

        MAX(CASE WHEN biomarker = 'ige_total'
                  AND rn = 1
                 THEN value_num END)
            AS ige_total_recent,

        MAX(CASE WHEN biomarker = 'crp'
                  AND rn = 1
                 THEN value_num END)
            AS crp_recent,

        MAX(CASE WHEN biomarker = 'neut_abs'
                  AND rn = 1
                 THEN value_num END)
            AS neut_abs_recent,

        MAX(CASE WHEN biomarker = 'feno'
                  AND rn = 1
                 THEN value_num END)
            AS feno_recent,

        MAX(CASE WHEN biomarker = 'eos_pct'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS eos_pct_date,

        MAX(CASE WHEN biomarker = 'eos_abs'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS eos_abs_date,

        MAX(CASE WHEN biomarker = 'ige_total'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS ige_total_date,

        MAX(CASE WHEN biomarker = 'crp'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS crp_date,

        MAX(CASE WHEN biomarker = 'neut_abs'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS neut_abs_date,

        MAX(CASE WHEN biomarker = 'feno'
                  AND rn = 1
                 THEN ResultDateTime END)
            AS feno_date

    FROM lab_ranked
    WHERE rn = 1
    GROUP BY PatientID
),

/* 14) Outcome definition:
       any asthma "exacerbation-ish" dx in 365d AFTER index_date */
future_exacerbation AS (
    SELECT
        w.PatientID,

        MAX(
            CASE
                WHEN CAST(COALESCE(dp.StartDate, ef.EncounterContactDate) AS DATE)
                        >= w.index_date

                 AND CAST(COALESCE(dp.StartDate, ef.EncounterContactDate) AS DATE)
                        < w.fu_end_date

                 AND (
                        LOWER(dc.DiagnosisName) LIKE '%exacerbation%'
                     OR LOWER(dc.DiagnosisName) LIKE '%status asthmaticus%'
                     OR (
                            (
                                dc.DiagnosisCode LIKE 'J45%'
                             OR dc.DiagnosisCode LIKE '493%'
                             OR LOWER(dc.DiagnosisName) LIKE '%asthma%'
                            )
                            AND (
                                LOWER(dc.DiagnosisName) LIKE '%acute%'
                             OR LOWER(dc.DiagnosisName) LIKE '%severe%'
                            )
                        )
                     )

                THEN 1 ELSE 0
            END
        ) AS y_future_exacerbation

    FROM windowed_patients w

    LEFT JOIN rpt.CDM_DiagnosisProblemFact dp
        ON dp.PatientID = w.PatientID

    LEFT JOIN rpt.CDM_EncounterFact ef
        ON ef.PatientEncounterCSNID = dp.PatientEncounterCSNID

    LEFT JOIN rpt.DIM_DiagnosisCodeDim dc
        ON dp.DiagnosisID = dc.DiagnosisID

    GROUP BY w.PatientID
)

/* 15) Final feature matrix */
SELECT
    w.PatientID,
    w.index_date,

    d.Sex,
    d.Ethnicity,
    d.FirstRace,
    d.SmokingStatus,

    CASE
        WHEN d.BirthDate IS NOT NULL
        THEN DATEDIFF(YEAR, d.BirthDate, w.index_date)
        ELSE NULL
    END AS PatientAgeAtIndex,

    COALESCE(e.lb_total_encounters, 0)
        AS lb_total_encounters,

    COALESCE(e.lb_ed_visits, 0)
        AS lb_ed_visits,

    COALESCE(e.lb_inpatient_encounters, 0)
        AS lb_inpatient_encounters,

    COALESCE(m.lb_saba_orders, 0)
        AS lb_saba_orders,

    COALESCE(m.lb_saba_prn_orders, 0)
        AS lb_saba_prn_orders,

    COALESCE(m.lb_ics_orders, 0)
        AS lb_ics_orders,

    COALESCE(m.lb_ics_laba_orders, 0)
        AS lb_ics_laba_orders,

    COALESCE(m.lb_montelukast_orders, 0)
        AS lb_montelukast_orders,

    COALESCE(m.lb_oral_steroid_orders, 0)
        AS lb_oral_steroid_orders,

    COALESCE(c.lb_allergic_rhinitis_flag, 0)
        AS lb_allergic_rhinitis_flag,

    COALESCE(c.lb_obesity_flag, 0)
        AS lb_obesity_flag,

    COALESCE(al.lb_any_allergy_record, 0)
        AS lb_any_allergy_record,

    COALESCE(al.lb_allergy_count, 0)
        AS lb_allergy_count,

    lf.eos_pct_recent,
    CASE
        WHEN lf.eos_pct_recent IS NULL THEN 1
        ELSE 0
    END AS eos_pct_missing,

    lf.eos_abs_recent,
    CASE
        WHEN lf.eos_abs_recent IS NULL THEN 1
        ELSE 0
    END AS eos_abs_missing,

    lf.ige_total_recent,
    CASE
        WHEN lf.ige_total_recent IS NULL THEN 1
        ELSE 0
    END AS ige_total_missing,

    lf.crp_recent,
    CASE
        WHEN lf.crp_recent IS NULL THEN 1
        ELSE 0
    END AS crp_missing,

    lf.neut_abs_recent,
    CASE
        WHEN lf.neut_abs_recent IS NULL THEN 1
        ELSE 0
    END AS neut_abs_missing,

    lf.feno_recent,
    CASE
        WHEN lf.feno_recent IS NULL THEN 1
        ELSE 0
    END AS feno_missing,

    COALESCE(y.y_future_exacerbation, 0)
        AS y_future_exacerbation

FROM windowed_patients w

LEFT JOIN demographics d
    ON d.PatientID = w.PatientID

LEFT JOIN encounters_lb e
    ON e.PatientID = w.PatientID

LEFT JOIN med_features_lb m
    ON m.PatientID = w.PatientID

LEFT JOIN comorbid_dx_lb c
    ON c.PatientID = w.PatientID

LEFT JOIN allergy_lb al
    ON al.PatientID = w.PatientID

LEFT JOIN lab_features lf
    ON lf.PatientID = w.PatientID

LEFT JOIN future_exacerbation y
    ON y.PatientID = w.PatientID
;
