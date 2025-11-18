# Scorecard for Catalog Services
resource "dx_scorecard" "production_readiness_example" {
  name                           = "Production Readiness - POC READY"
  description                    = "This scorecard scores a services production readiness"
  type                           = "LEVEL"
  entity_filter_type             = "entity_types"
  entity_filter_type_identifiers = ["service"]
  evaluation_frequency_hours     = 4
  empty_level_label              = "Not Production Ready"
  empty_level_color              = "#cccccc"
  published                      = false

  tags = [
    { value = "production" },
    { value = "service-readiness" }
  ]

  levels = {
    prod-ready = {
      name  = "Production Ready"
      color = "#23fa3e"
      rank  = 1
    },
  }

  checks = {
    owner_check = {
      name                = "Owner is defined"
      scorecard_level_key = "prod-ready"
      ordering            = 0

      description        = "Is the owner defined for this service?"
      sql                = <<-EOT
        SELECT CASE
          WHEN count(*) > 0 THEN 'PASS'
          ELSE 'FAIL'
        END AS status
      FROM dx_catalog_entities e
        JOIN dx_catalog_entity_owners o ON e.id = o.entity_id
      WHERE e.identifier = $entity_identifier;
      EOT
      output_enabled     = false
      published          = true
      estimated_dev_days = 1.5
    },

    service_tier_check = {
      name                = "Service tier is defined"
      scorecard_level_key = "prod-ready"
      ordering            = 2

      description        = "Is the tier defined for this service?"
      sql                = <<-EOT
        SELECT CASE
          WHEN count(*) > 0 THEN 'PASS'
          ELSE 'FAIL'
        END AS status
      FROM dx_catalog_entities e
        JOIN dx_catalog_entity_properties ep ON e.id = ep.entity_id
        JOIN dx_catalog_properties p ON p.id = ep.property_id
      WHERE e.identifier = $entity_identifier
        AND p.identifier = 'service-tier';
      EOT
      output_enabled     = false
      published          = true
      estimated_dev_days = 1.5
    },

    incident_runbook_check = {
      name                = "Incident runbook is defined"
      scorecard_level_key = "prod-ready"
      ordering            = 3

      description        = "When issues and incidents occur in production, the pressure to resolve these issues can make it hard to think methodically. Having an official runbook document for what to do in common scenarios helps each member of the team be ready to take on-call shifts and respond effectively to issues."
      sql                = <<-EOT
        SELECT CASE
          WHEN count(*) > 0 THEN 'PASS'
          ELSE 'FAIL'
        END AS status
      FROM dx_catalog_entities e
        JOIN dx_catalog_entity_properties ep ON e.id = ep.entity_id
        JOIN dx_catalog_properties p ON p.id = ep.property_id
      WHERE e.identifier = $entity_identifier
        AND p.identifier = 'incident-runbook';
      EOT
      output_enabled     = false
      published          = true
      estimated_dev_days = 1.5
    },

    readme_check = {
      name                = "README.md file exists"
      scorecard_level_key = "prod-ready"
      ordering            = 4

      description        = "README.md is the hub of information for someone looking to do work on a service."
      sql                = <<-EOT
        SELECT CASE
          WHEN count(*) > 0 THEN 'PASS'
          ELSE 'FAIL'
        END AS status
      FROM dx_catalog_entities e
        JOIN dx_catalog_entity_properties ep ON e.id = ep.entity_id
        JOIN dx_catalog_properties p ON p.id = ep.property_id
      WHERE e.identifier = $entity_identifier
        AND p.identifier = 'readme';
      EOT
      output_enabled     = false
      published          = true
      estimated_dev_days = 1.5
    },

    deployment_check = {
      name                = "Service deployed in last 90 days"
      scorecard_level_key = "prod-ready"
      ordering            = 5

      description        = "Services should be deployed frequently to ensure freshness. All services should have deployed within the last 90 days."
      sql                = <<-EOT
        WITH entity_deployments AS (
          SELECT dce.id as entity_id,
            dce.name as entity_name,
            dce.identifier as entity_identifier,
            dceae.name as service_alias,
            MAX(d.deployed_at) as last_deployment_date
          FROM dx_catalog_entities dce
            LEFT JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
            LEFT JOIN dx_catalog_entity_alias_entries dceae ON dcea.id = dceae.entity_alias_id
            AND dcea.entity_alias_type = 'dx_deployment_service'
            LEFT JOIN deployments d ON d.service = dceae.name
          WHERE d.deployed_at IS NOT NULL
            AND dce.identifier = $entity_identifier
          GROUP BY dce.id,
            dce.name,
            dce.identifier,
            dceae.name
        )
        SELECT CASE
            WHEN CURRENT_DATE - DATE(last_deployment_date) < 70 THEN 'PASS'
            WHEN CURRENT_DATE - DATE(last_deployment_date) < 90 THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          CONCAT(
            '🕒 **Your service was last deployed ',
            CURRENT_DATE - DATE(last_deployment_date),
            ' days ago.**'
          ) AS message,
          entity_name,
          entity_identifier,
          service_alias,
          last_deployment_date,
          CURRENT_DATE - DATE(last_deployment_date) as days_since_last_deployment
        FROM entity_deployments
        ORDER BY days_since_last_deployment ASC
      EOT
      output_enabled     = false
      published          = true
      estimated_dev_days = 1.5
    }
  }
}

# CI Reliability Scorecard
resource "dx_scorecard" "ci_reliability" {
  checks = {
    "p_50" = {
      description    = "Time spent waiting for P50 is 10 minutes or less"
      name           = "P50"
      scorecard_level_key = "bronze"
      ordering       = 0
      output_enabled = true
      output_type    = "string"
      published      = true
      sql            = <<-EOT
                -- Scorecard check: P50 Build Wait Time ≤ 10 minutes
                -- This check calculates the median (p50) build duration for the service
                -- and passes if it's 10 minutes (600 seconds) or less
                
                WITH entity_repo AS (
                  -- Step 1: Get the repository name for this specific entity
                  SELECT dceae.name AS repository_name
                  FROM dx_catalog_entities dce
                  JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
                  JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id
                  WHERE dce.identifier = $entity_identifier
                    AND dce.entity_type_identifier = 'service'
                    AND dcea.entity_alias_type = 'github_repo'
                ),
                build_durations AS (
                  -- Step 2: Get build durations for this entity's repository
                  SELECT pr.duration
                  FROM entity_repo er
                  JOIN pipeline_runs pr ON pr.repository = er.repository_name
                  WHERE pr.duration IS NOT NULL
                    AND pr.duration > 0
                ),
                p50_calculation AS (
                  -- Step 3: Calculate P50 build duration
                  SELECT 
                    percentile_cont(0.5) WITHIN GROUP (ORDER BY duration) AS p50_duration,
                    COUNT(*) AS total_builds
                  FROM build_durations
                )
                -- Step 4: Return check results
                SELECT 
                  CASE
                    WHEN p50.total_builds = 0 THEN 'FAIL'
                    WHEN p50.p50_duration <= 600 THEN 'PASS'
                    WHEN p50.p50_duration <= 900 THEN 'WARN'
                    ELSE 'FAIL'
                  END AS status,
                  ROUND(COALESCE(p50.p50_duration, 0)::numeric, 0) AS output,
                  CASE
                    WHEN p50.total_builds = 0 THEN 'No builds found for this service'
                    ELSE CONCAT('P50 build duration: ', ROUND(COALESCE(p50.p50_duration, 0)::numeric / 60, 1), ' minutes (', p50.total_builds, ' builds)')
                  END AS message
                FROM p50_calculation p50;
            EOT
    },
    "p_75" = {
      name           = "P75"
      scorecard_level_key = "bronze"
      ordering       = 1
      output_enabled = true
      output_type    = "string"
      published      = true
      sql            = <<-EOT
                -- Scorecard check: P75 Build Wait Time ≤ 30 minutes
                -- This check calculates the 75th percentile (p75) build duration for the service
                -- and passes if it's 30 minutes (1800 seconds) or less
                
                WITH entity_repo AS (
                  -- Step 1: Get the repository name for this specific entity
                  SELECT dceae.name AS repository_name
                  FROM dx_catalog_entities dce
                  JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
                  JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id
                  WHERE dce.identifier = $entity_identifier
                    AND dce.entity_type_identifier = 'service'
                    AND dcea.entity_alias_type = 'github_repo'
                ),
                build_durations AS (
                  -- Step 2: Get build durations for this entity's repository
                  SELECT pr.duration
                  FROM entity_repo er
                  JOIN pipeline_runs pr ON pr.repository = er.repository_name
                  WHERE pr.duration IS NOT NULL
                    AND pr.duration > 0
                ),
                p75_calculation AS (
                  -- Step 3: Calculate P75 build duration
                  SELECT 
                    percentile_cont(0.75) WITHIN GROUP (ORDER BY duration) AS p75_duration,
                    COUNT(*) AS total_builds
                  FROM build_durations
                )
                -- Step 4: Return check results
                SELECT 
                  CASE
                    WHEN p75.total_builds = 0 THEN 'FAIL'
                    WHEN p75.p75_duration <= 1800 THEN 'PASS'
                    WHEN p75.p75_duration <= 2700 THEN 'WARN'
                    ELSE 'FAIL'
                  END AS status,
                  ROUND(COALESCE(p75.p75_duration, 0)::numeric, 0) AS output,
                  CASE
                    WHEN p75.total_builds = 0 THEN 'No builds found for this service'
                    ELSE CONCAT('P75 build duration: ', ROUND(COALESCE(p75.p75_duration, 0)::numeric / 60, 1), ' minutes (', p75.total_builds, ' builds)')
                  END AS message
                FROM p75_calculation p75
            EOT
    },
    "p_90" = {
      name           = "P90"
      scorecard_level_key = "silver"
      ordering       = 0
      output_enabled = true
      output_type    = "string"
      published      = true
      sql            = <<-EOT
                -- Scorecard check: P90 Build Wait Time ≤ 5 minutes
                -- This check calculates the 90th percentile (p90) build duration for the service
                -- and passes if it's 5 minutes (300 seconds) or less
                
                WITH entity_repo AS (
                  -- Step 1: Get the repository name for this specific entity
                  SELECT dceae.name AS repository_name
                  FROM dx_catalog_entities dce
                  JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
                  JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id
                  WHERE dce.identifier = $entity_identifier
                    AND dce.entity_type_identifier = 'service'
                    AND dcea.entity_alias_type = 'github_repo'
                ),
                build_durations AS (
                  -- Step 2: Get build durations for this entity's repository
                  SELECT pr.duration
                  FROM entity_repo er
                  JOIN pipeline_runs pr ON pr.repository = er.repository_name
                  WHERE pr.duration IS NOT NULL
                    AND pr.duration > 0
                ),
                p90_calculation AS (
                  -- Step 3: Calculate P90 build duration
                  SELECT 
                    percentile_cont(0.9) WITHIN GROUP (ORDER BY duration) AS p90_duration,
                    COUNT(*) AS total_builds
                  FROM build_durations
                )
                -- Step 4: Return check results
                SELECT 
                  CASE
                    WHEN p90.total_builds = 0 THEN 'FAIL'
                    WHEN p90.p90_duration <= 300 THEN 'PASS'
                    WHEN p90.p90_duration <= 450 THEN 'WARN'
                    ELSE 'FAIL'
                  END AS status,
                  ROUND(COALESCE(p90.p90_duration, 0)::numeric, 0) AS output,
                  CASE
                    WHEN p90.total_builds = 0 THEN 'No builds found for this service'
                    ELSE CONCAT('P90 build duration: ', ROUND(COALESCE(p90.p90_duration, 0)::numeric / 60, 1), ' minutes (', p90.total_builds, ' builds)')
                  END AS message
                FROM p90_calculation p90
            EOT
    },
    "success_rate" = {
      description    = "Build success rate 98% or higher"
      name           = "Success rate"
      scorecard_level_key = "gold"
      ordering       = 1
      output_enabled = true
      output_type    = "string"
      published      = true
      sql            = <<-EOT
                -- Scorecard check: Build Stability ≥ 98%
                -- This check calculates the build success rate for the service
                -- and passes if it's 98% or above
                
                WITH entity_repo AS (
                  -- Step 1: Get the repository name for this specific entity
                  SELECT dceae.name AS repository_name
                  FROM dx_catalog_entities dce
                  JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
                  JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id
                  WHERE dce.identifier = $entity_identifier
                    AND dce.entity_type_identifier = 'service'
                    AND dcea.entity_alias_type = 'github_repo'
                ),
                build_success_calculation AS (
                  -- Step 2: Calculate build success rate for this entity's repository
                  SELECT 
                    SUM(CASE WHEN pr.status = 'success' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0) AS success_rate,
                    COUNT(*) AS total_builds,
                    SUM(CASE WHEN pr.status = 'success' THEN 1 ELSE 0 END) AS successful_builds
                  FROM entity_repo er
                  JOIN pipeline_runs pr ON pr.repository = er.repository_name
                  WHERE pr.status IS NOT NULL
                    AND pr.status IN ('success', 'failure', 'failed', 'error')
                )
                -- Step 3: Return check results
                SELECT 
                  CASE
                    WHEN bsc.total_builds = 0 THEN 'FAIL'
                    WHEN bsc.success_rate >= 98 THEN 'PASS'
                    WHEN bsc.success_rate > 95 THEN 'WARN'
                    ELSE 'FAIL'
                  END AS status,
                  ROUND(COALESCE(bsc.success_rate, 0)::numeric, 1) AS output,
                  CASE
                    WHEN bsc.total_builds = 0 THEN 'No builds found for this service'
                    ELSE CONCAT('Build success rate: ', ROUND(COALESCE(bsc.success_rate, 0)::numeric, 1), '% (', bsc.successful_builds, '/', bsc.total_builds, ' builds)')
                  END AS message
                FROM build_success_calculation bsc
            EOT
    },
  }
  description        = ""
  empty_level_color  = "#cbd5e1"
  empty_level_label  = "Incomplete"
  entity_filter_type = "entity_types"
  entity_filter_type_identifiers = [
    "service",
  ]
  evaluation_frequency_hours = 4
  levels = {
    "bronze" = {
      color = "#FB923C"
      name  = "Bronze"
      rank  = 1
    },
    "gold" = {
      color = "#FBBF24"
      name  = "Gold"
      rank  = 3
    },
    "silver" = {
      color = "#9CA3AF"
      name  = "Silver"
      rank  = 2
    },
  }
  name = "Example CI Service Reliability"
  type = "LEVEL"
}

# SonarQube Scorecard
resource "dx_scorecard" "sonarqube_insights" {
  name                           = "SonarQube Insights"
  description                    = "This scorecard scores against SonarQube Metrics. To create a new check, simply replace the \"metric_name\" in the vars CTE to be one of the metric names in `select distinct name from sonarqube_metrics`"
  type                           = "POINTS"
  entity_filter_type             = "entity_types"
  entity_filter_type_identifiers = ["service"]
  evaluation_frequency_hours     = 4
  published                      = false

  check_groups = {
    checks = {
      name     = "Checks"
      ordering = 0
    }
    complexity = {
      name     = "Complexity"
      ordering = 2
    }
    coverage = {
      name     = "Coverage"
      ordering = 3
    }
    issues = {
      name     = "Issues"
      ordering = 4
    }
    maintainability = {
      name     = "Maintainability"
      ordering = 5
    }
  }

  checks = {
    sonarqube_project_defined = {
      name                      = "sonarqube project defined"
      scorecard_check_group_key = "checks"
      ordering                  = 0
      sql                       = <<-EOT
        SELECT CASE
            WHEN COUNT(*) > 0 THEN 'PASS'
            ELSE 'FAIL'
          END AS status
        FROM dx_catalog_entities e
          JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
          AND ea.entity_alias_type = 'sonarqube_project'
          JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
        WHERE e.identifier = $entity_identifier
      EOT
      output_enabled            = false
      published                 = true
      points                    = 1
    }

    cognitive_complexity = {
      name                      = "Cognitive Complexity < 500"
      scorecard_check_group_key = "complexity"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Cognitive Complexity' as metric_name,
          500 as pass_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric <= pass_threshold THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      output_aggregation        = null
      published                 = true
      points                    = 1
    }

    cyclomatic_complexity = {
      name                      = "Cyclomatic Complexity < 1000"
      scorecard_check_group_key = "complexity"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Cyclomatic Complexity' as metric_name,
          800 as pass_threshold,
          1000 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    code_coverage = {
      name                      = "Code Coverage > 80%"
      scorecard_check_group_key = "coverage"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Coverage' as metric_name,
          90 as pass_threshold,
          80 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric > pass_threshold THEN 'PASS'
            WHEN metric_value::numeric > warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          CONCAT(metric_value, '%') AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    coverage_on_new_code = {
      name                      = "Coverage on New Code > 80%"
      scorecard_check_group_key = "coverage"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Coverage on New Code' as metric_name,
          90 as pass_threshold,
          80 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric > pass_threshold THEN 'PASS'
            WHEN metric_value::numeric > warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          CONCAT(ROUND(metric_value::numeric, 2), '%') AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    critical_issues = {
      name                      = "< 5 Critical Issues"
      scorecard_check_group_key = "issues"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Critical Issues' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    major_issues = {
      name                      = "< 5 Major Issues"
      scorecard_check_group_key = "issues"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Major Issues' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    code_smells = {
      name                      = "< 5 Code Smells"
      scorecard_check_group_key = "maintainability"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Code Smells' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    maintainability_rating = {
      name                      = "Maintainability Rating < 5"
      scorecard_check_group_key = "maintainability"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Maintainability Rating' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarqube_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarqube_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarqube_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarqube_projects sp
            JOIN entity_sonarqube_projects esp ON sp.source_key = esp.identifier
            JOIN sonarqube_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarqube_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarqube_project_metrics
        JOIN vars ON entity_sonarqube_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }
  }
}

# SonarSource Scorecard
resource "dx_scorecard" "sonarcloud_insights" {
  name                           = "SonarCloud Insights"
  description                    = "This scorecard scores against SonarCloud Metrics. To create a new check, simply replace the \"metric_name\" in the vars CTE to be one of the metric names in `select distinct name from sonarcloud_metrics`"
  type                           = "POINTS"
  entity_filter_type             = "entity_types"
  entity_filter_type_identifiers = ["service"]
  evaluation_frequency_hours     = 4
  published                      = false

  check_groups = {
    checks = {
      name     = "Checks"
      ordering = 0
    }
    complexity = {
      name     = "Complexity"
      ordering = 2
    }
    coverage = {
      name     = "Coverage"
      ordering = 3
    }
    issues = {
      name     = "Issues"
      ordering = 4
    }
    maintainability = {
      name     = "Maintainability"
      ordering = 5
    }
  }

  checks = {
    sonarcloud_project_defined = {
      name                      = "sonarcloud project defined"
      scorecard_check_group_key = "checks"
      ordering                  = 0
      sql                       = <<-EOT
        SELECT CASE
            WHEN COUNT(*) > 0 THEN 'PASS'
            ELSE 'FAIL'
          END AS status
        FROM dx_catalog_entities e
          JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
          AND ea.entity_alias_type = 'sonarcloud_project'
          JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
        WHERE e.identifier = $entity_identifier
      EOT
      output_enabled            = false
      published                 = true
      points                    = 1
    }

    cognitive_complexity = {
      name                      = "Cognitive Complexity < 500"
      scorecard_check_group_key = "complexity"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Cognitive Complexity' as metric_name,
          500 as pass_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric <= pass_threshold THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      output_aggregation        = null
      published                 = true
      points                    = 1
    }

    cyclomatic_complexity = {
      name                      = "Cyclomatic Complexity < 1000"
      scorecard_check_group_key = "complexity"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Cyclomatic Complexity' as metric_name,
          800 as pass_threshold,
          1000 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    code_coverage = {
      name                      = "Code Coverage > 80%"
      scorecard_check_group_key = "coverage"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Coverage' as metric_name,
          90 as pass_threshold,
          80 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric > pass_threshold THEN 'PASS'
            WHEN metric_value::numeric > warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          CONCAT(metric_value, '%') AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    coverage_on_new_code = {
      name                      = "Coverage on New Code > 80%"
      scorecard_check_group_key = "coverage"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Coverage on New Code' as metric_name,
          90 as pass_threshold,
          80 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric > pass_threshold THEN 'PASS'
            WHEN metric_value::numeric > warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          CONCAT(ROUND(metric_value::numeric, 2), '%') AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    critical_issues = {
      name                      = "< 5 Critical Issues"
      scorecard_check_group_key = "issues"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Critical Issues' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    major_issues = {
      name                      = "< 5 Major Issues"
      scorecard_check_group_key = "issues"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Major Issues' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    code_smells = {
      name                      = "< 5 Code Smells"
      scorecard_check_group_key = "maintainability"
      ordering                  = 0
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Code Smells' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }

    maintainability_rating = {
      name                      = "Maintainability Rating < 5"
      scorecard_check_group_key = "maintainability"
      ordering                  = 1
      sql                       = <<-EOT
        WITH vars AS (
          SELECT 'Maintainability Rating' as metric_name,
          3 as pass_threshold,
          5 as warn_threshold
        ),
        entity_sonarcloud_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'sonarcloud_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_sonarcloud_project_metrics AS (
          SELECT pm.id,
            sp.name as project_name,
            m.name as metric_name,
            m.domain as metric_domain,
            pm.date,
            pm.value as metric_value
          FROM sonarcloud_projects sp
            JOIN entity_sonarcloud_projects esp ON sp.source_key = esp.identifier
            JOIN sonarcloud_project_metrics pm ON pm.project_id = sp.id
            JOIN sonarcloud_metrics m ON m.id = pm.metric_id
          WHERE m.name = (
              SELECT metric_name
              FROM vars
            )
            AND pm.value is not null
          ORDER BY date desc
          LIMIT 1
        )
        SELECT CASE
            WHEN metric_value::numeric < pass_threshold  THEN 'PASS'
            WHEN metric_value::numeric < warn_threshold THEN 'WARN'
            ELSE 'FAIL'
          END AS status,
          metric_value AS output
        FROM entity_sonarcloud_project_metrics
        JOIN vars ON entity_sonarcloud_project_metrics.metric_name = vars.metric_name
      EOT
      output_enabled            = true
      output_type               = "string"
      published                 = true
      points                    = 1
    }
  }
}

# GitHub Repo Scorecard
resource "dx_scorecard" "github_repo_configuration" {
  check_groups = null
  checks = {
    admins_must_follow_rules = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Admins must follow rules"
      ordering                  = 1
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "production_ready"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'enforce_admins' = 'false' THEN 'FAIL'\n    WHEN cd.value->>'enforce_admins' = 'true' THEN 'PASS'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No branch_protection:enforce_admins record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'branch_protection:enforce_admins';"
    }
    branch_is_not_locked = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Branch is not locked"
      ordering                  = 0
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "production_ready"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'lock_branch' = 'false' THEN 'PASS'\n    WHEN cd.value->>'lock_branch' = 'true' THEN 'FAIL'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No branch_protection:lock_branch record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'branch_protection:lock_branch';"
    }
    deletions_are_forbidden = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Deletions are Forbidden"
      ordering                  = 2
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "minimum"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'allow_deletions' = 'false' THEN 'PASS'\n    WHEN cd.value->>'allow_deletions' = 'true' THEN 'FAIL'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No branch_protection:allow_deletions record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'branch_protection:allow_deletions';"
    }
    force_pushes_disabled = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Force Pushes Disabled"
      ordering                  = 3
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "minimum"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'allow_force_pushes' = 'false' THEN 'PASS'\n    WHEN cd.value->>'allow_force_pushes' = 'true' THEN 'FAIL'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No branch_protection:allow_force_pushes record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'branch_protection:allow_force_pushes';"
    }
    has_codeowners_file = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Has CODEOWNERS file"
      ordering                  = 0
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "recommended"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'exists' = 'false' THEN 'FAIL'\n    WHEN cd.value->>'exists' = 'true' THEN 'PASS'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No codeowners:exists record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'codeowners:exists';"
    }
    has_git_hub_repo = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Has GitHub Repo"
      ordering                  = 0
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = false
      output_type               = null
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "minimum"
      sql                       = "SELECT \n  dce.identifier AS entity_identifier,\n  dce.name AS entity_name,\n  CASE \n    WHEN dcea.id IS NOT NULL THEN 'PASS'\n    ELSE 'FAIL'\n  END AS status,\n  dceae.name AS github_repo_name,\n  1 as count\nFROM dx_catalog_entities dce\nLEFT JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id \n  AND dcea.entity_alias_type = 'github_repo'\nLEFT JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id\nWHERE dce.identifier = $entity_identifier"
    }
    has_readme_file = {
      description               = null
      estimated_dev_days        = null
      external_url              = null
      filter_message            = null
      filter_sql                = null
      name                      = "Has README file"
      ordering                  = 1
      output_aggregation        = null
      output_custom_options     = null
      output_enabled            = true
      output_type               = "string"
      points                    = null
      published                 = true
      scorecard_check_group_key = null
      scorecard_level_key       = "minimum"
      sql                       = "WITH repo_info AS (\n  SELECT string_to_array($entity_github_repo_ids, ',') AS repo_ids\n)\nSELECT CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'FAIL'\n    WHEN cd.value->>'exists' = 'false' THEN 'FAIL'\n    WHEN cd.value->>'exists' = 'true' THEN 'PASS'\n    ELSE 'FAIL'\n  END AS status,\n  CASE\n    WHEN array_length(ri.repo_ids, 1) > 1 THEN 'There is more than 1 repo attached to this service.'\n    WHEN cd.reference IS NULL THEN 'No readme:exists record found.'\n    ELSE NULL\n  END AS output,\n  1 AS count\nFROM repo_info ri\n  LEFT JOIN custom_data cd ON cd.reference = $entity_github_repo_ids\n  AND cd.key = 'readme:exists';"
    }
  }
  description                    = null
  empty_level_color              = "#cbd5e1"
  empty_level_label              = "Incomplete"
  entity_filter_sql              = null
  entity_filter_type             = "entity_types"
  entity_filter_type_identifiers = ["service"]
  evaluation_frequency_hours     = 4
  levels = {
    minimum = {
      color = "#FB923C"
      name  = "Minimum"
      rank  = 1
    }
    recommended = {
      color = "#9CA3AF"
      name  = "Recommended"
      rank  = 2
    }
    production_ready = {
      color = "#FBBF24"
      name  = "Production Ready"
      rank  = 3
    }

  }
  name      = "GitHub Repo Configuration"
  published = false
  tags      = null
  type      = "LEVEL"
}

# Snyk Issues Scorecard
resource "dx_scorecard" "snyk_issues" {
  name                           = "[Service] Snyk Issues"
  description                    = null
  type                           = "LEVEL"
  entity_filter_type             = "entity_types"
  entity_filter_type_identifiers = ["service"]
  evaluation_frequency_hours     = 4
  empty_level_label              = "Has High/Critical Snyk Issues"
  empty_level_color              = "#cbd5e1"
  published                      = false

  levels = {
    required = {
      name  = "Required"
      color = "#000000"
      rank  = 1
    }
    bronze = {
      name  = "Bronze"
      color = "#FB923C"
      rank  = 2
    }
    silver = {
      name  = "Silver"
      color = "#9CA3AF"
      rank  = 3
    }
    gold = {
      name  = "Gold"
      color = "#FBBF24"
      rank  = 4
    }
  }

  checks = {
    required = {
      name                = "Has Snky Project"
      description         = null
      scorecard_level_key = "required"
      ordering            = 0
      sql                 = <<-EOT
        SELECT dce.identifier AS entity_identifier,
          dce.name AS entity_name,
          CASE
            WHEN dcea.id IS NOT NULL THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          dceae.name AS snyk_project_name,
          1 as count
        FROM dx_catalog_entities dce
          LEFT JOIN dx_catalog_entity_aliases dcea ON dce.id = dcea.entity_id
          AND dcea.entity_alias_type = 'snyk_project'
          LEFT JOIN dx_catalog_entity_alias_entries dceae ON dceae.entity_alias_id = dcea.id
        WHERE dce.identifier = $entity_identifier
      EOT
      output_enabled      = false
      output_type         = null
      output_aggregation  = null
      published           = true
    }

    high_critical_snyk_issues = {
      name                = "No \"High/Critical\" Snyk Issues Open"
      description         = null
      scorecard_level_key = "bronze"
      ordering            = 0
      sql                 = <<-EOT
        WITH entity_snyk_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'snyk_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_snyk_project_issues AS (
          SELECT si.*
          FROM entity_snyk_projects esp
            JOIN snyk_projects sp ON esp.identifier = sp.source_id
            JOIN snyk_issues si ON si.project_id = sp.id
          WHERE si.status = 'open'
        )
        SELECT CASE
            WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          COUNT(*) AS output
        FROM entity_snyk_project_issues
        WHERE effective_severity_level IN ('critical', 'high')
      EOT
      output_enabled      = true
      output_type         = "number"
      output_aggregation  = "mean"
      published           = true
    }

    medium_snyk_issues = {
      name                = "No \"Medium\" Snyk Issues Open"
      description         = null
      scorecard_level_key = "silver"
      ordering            = 0
      sql                 = <<-EOT
        WITH entity_snyk_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'snyk_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_snyk_project_issues AS (
          SELECT si.*
          FROM entity_snyk_projects esp
            JOIN snyk_projects sp ON esp.identifier = sp.source_id
            JOIN snyk_issues si ON si.project_id = sp.id
          WHERE si.status = 'open'
        )
        SELECT CASE
            WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          COUNT(*) AS output
        FROM entity_snyk_project_issues
        WHERE effective_severity_level = 'medium'
      EOT
      output_enabled      = true
      output_type         = "number"
      output_aggregation  = "mean"
      published           = true
    }

    low_snyk_issues = {
      name                = "No \"Low\" Snyk Issues Open"
      description         = null
      scorecard_level_key = "gold"
      ordering            = 0
      sql                 = <<-EOT
        WITH entity_snyk_projects AS (
          SELECT eae.identifier
          FROM dx_catalog_entities e
            JOIN dx_catalog_entity_aliases ea ON ea.entity_id = e.id
            AND ea.entity_alias_type = 'snyk_project'
            JOIN dx_catalog_entity_alias_entries eae ON eae.entity_alias_id = ea.id
          WHERE e.identifier = $entity_identifier
        ),
        entity_snyk_project_issues AS (
          SELECT si.*
          FROM entity_snyk_projects esp
            JOIN snyk_projects sp ON esp.identifier = sp.source_id
            JOIN snyk_issues si ON si.project_id = sp.id
          WHERE si.status = 'open'
        )
        SELECT CASE
            WHEN COUNT(*) = 0 THEN 'PASS'
            ELSE 'FAIL'
          END AS status,
          COUNT(*) AS output
        FROM entity_snyk_project_issues
        WHERE effective_severity_level = 'low'
      EOT
      output_enabled      = true
      output_type         = "number"
      output_aggregation  = "mean"
      published           = true
    }
  }
} 