# @file CohortMethod.R
#
# Copyright 2014 Observational Health Data Sciences and Informatics
#
# This file is part of CohortMethod
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# @author Observational Health Data Sciences and Informatics
# @author Patrick Ryan
# @author Marc Suchard
# @author Martijn Schuemie

executeSql <- function(conn, dbms, sql, profile = FALSE, progressBar = TRUE, reportTime = TRUE){
  if (profile)
    progressBar = FALSE
  sqlStatements = splitSql(sql)
  if (progressBar)
    pb <- txtProgressBar(style=3)
  start <- Sys.time()
  for (i in 1:length(sqlStatements)){
    sqlStatement <- sqlStatements[i]
    if (profile){
      sink(paste("statement_",i,".sql",sep=""))
      cat(sqlStatement)
      sink()
    }
    tryCatch ({   
      startQuery <- Sys.time()
      dbSendUpdate(conn, sqlStatement)
      if (profile){
        delta <- Sys.time() - startQuery
        writeLines(paste("Statement ",i,"took", delta, attr(delta,"units")))
      }
    } , error = function(err) {
      writeLines(paste("Error executing SQL:",err))
      
      #Write error report:
      filename <- paste(getwd(),"/errorReport.txt",sep="")
      sink(filename)
      error <<- err
      cat("DBMS:\n")
      cat(dbms)
      cat("\n\n")
      cat("Error:\n")
      cat(err$message)
      cat("\n\n")
      cat("SQL:\n")
      cat(sqlStatement)
      sink()
      
      writeLines(paste("An error report has been created at ", filename))
      break
    })
    if (progressBar)
      setTxtProgressBar(pb, i/length(sqlStatements))
  }
  if (progressBar)
    close(pb)
  if (reportTime) {
    delta <- Sys.time() - start
    writeLines(paste("Analysis took", signif(delta,3), attr(delta,"units")))
  }
  
}



#' @export
dbGetCohortData <- function(connectionDetails, 
                            cdmSchema = "CDM4_SIM",
                            resultsSchema = "CDM4_SIM",
                            targetDrugConceptId = 755695,
                            comparatorDrugConceptIds = 739138,
                            indicationConceptIds = 439926,
                            washoutWindow = 183,
                            indicationLookbackWindow = 183,
                            exposureExtensionWindow = 7,
                            studyStartDate = "",
                            studyEndDate = "",
                            exclusionConceptIds = c(4027133,4032243,4146536,2002282,2213572,2005890,43534760,21601019),
                            outcomeConceptId = 194133,
                            outcomeConditionTypeConceptIds = c(38000215,38000216,38000217,38000218,38000183,38000232),
                            maxOutcomeCount = 1,
                            useFf = TRUE){
  renderedSql <- loadRenderTranslateSql("CohortMethod.sql",
                                        packageName = "CohortMethod",
                                        dbms = connectionDetails$dbms,
                                        CDM_schema = cdmSchema,
                                        results_schema = resultsSchema,
                                        target_drug_concept_id = targetDrugConceptId,
                                        comparator_drug_concept_ids = comparatorDrugConceptIds,
                                        indication_concept_ids = indicationConceptIds,
                                        washout_window = washoutWindow,
                                        indication_lookback_window = indicationLookbackWindow,
                                        exposure_extension_window = exposureExtensionWindow,
                                        study_start_date = studyStartDate,
                                        study_end_date = studyEndDate,
                                        exclusion_concept_ids = exclusionConceptIds,
                                        outcome_concept_id = outcomeConceptId,
                                        outcome_condition_type_concept_ids = outcomeConditionTypeConceptIds,
                                        max_outcome_count = maxOutcomeCount)
  
  conn <- connect(connectionDetails)
  
  writeLines("Executing multiple queries. This could take a while")
  executeSql(conn,connectionDetails$dbms,renderedSql)
  
  outcomeSql <-"SELECT person_id AS row_id,num_outcomes AS y,time_to_outcome FROM #outcomes ORDER BY person_id"
  outcomeSql <- translateSql(outcomeSql,"sql server",connectionDetails$dbms)$sql
  
  cohortSql <-"SELECT cohort_id AS treatment, person_id AS row_id, datediff(dd, cohort_start_date, cohort_censor_date) AS time_to_censor FROM #cohorts ORDER BY person_id"
  cohortSql <- translateSql(cohortSql,"sql server",connectionDetails$dbms)$sql
  
  covariateSql <-"SELECT person_id AS row_id,covariate_id,covariate_value FROM #covariates ORDER BY person_id,covariate_id"
  covariateSql <- translateSql(covariateSql,"sql server",connectionDetails$dbms)$sql
  
  writeLines("Fetching data from server")
  start <- Sys.time()
  if (useFf){ # Use ff
    outcomes <- dbGetQuery.ffdf(conn,outcomeSql)
    cohorts <-  dbGetQuery.ffdf(conn,cohortSql)
    covariates <- dbGetQuery.ffdf(conn,covariateSql)
  } else { # Don't use ff
    outcomes <- dbGetQueryBatchWise(conn,outcomeSql)
    cohorts <-  dbGetQueryBatchWise(conn,cohortSql)
    covariates <- dbGetQueryBatchWise(conn,covariateSql)
  }
  delta <- Sys.time() - start
  writeLines(paste("Loading took", signif(delta,3), attr(delta,"units")))
  #Remove temp tables:
  renderedSql <- loadRenderTranslateSql("CMRemoveTempTables.sql",
                                        packageName = "CohortMethod",
                                        dbms = connectionDetails$dbms,
                                        CDM_schema = cdmSchema)
  
  executeSql(conn,connectionDetails$dbms,renderedSql,progressBar = FALSE,reportTime=FALSE)
  
  
  dummy <- dbDisconnect(conn)
  result <- list(outcomes = outcomes,
                 cohorts = cohorts,
                 covariates = covariates,
                 useFf = useFf    
  )
  class(result) <- "cohortData"
  result
}

save.cohortData <- function(cohortData, file){
  if (missing(cohortData))
    stop("Must specify cohortData")
  if (missing(file))
    stop("Must specify file")
  if (class(cohortData) != "cohortData")
    stop("Data not of class cohortData")
  
  if (cohortData$useFf){
    out1 <- cohortData$outcomes
    out2 <- cohortData$cohorts
    out3 <- cohortData$covariates
    save.ffdf(out1,out2,out3,dir=file)
  } else {
    save(cohortData,file=file)
  }
}

#save.cohortData(x,"c:/temp/x")

load.cohortData <- function(file){
  if (file.info(file)$isdir){ #useFf
    e <- new.env()
    load.ffdf(file,e)
    result <- list(outcomes = get("out1", envir=e),
                   cohorts = get("out2", envir=e),
                   covariates = get("out3", envir=e),
                   useFf = TRUE    
    )
    class(result) <- "cohortData"
    rm(e)
    result 
  } else { #useFf
    e <- new.env()
    load(file,e)
    cohortData <- get("cohortData", envir=e)
    rm(e)
    cohortData 
  }
}
