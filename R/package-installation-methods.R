# Copyright 2018 Opening Reproducible Research (https://o2r.info)

# pkgs is a data.frame of packages with the columns name, version, and source (either "CRAN" or "github")
# function returns the given Dockerfile object with the required instructions
add_install_instructions <- function(base_dockerfile,
                                     pkgs,
                                     platform,
                                     soft,
                                     offline,
                                     versioned_libs,
                                     versioned_packages,
                                     filter_baseimage_pkgs,
                                     filter_deps_by_image = FALSE) {
  if (is.null(pkgs) || nrow(pkgs) < 1) {
    futile.logger::flog.debug("Input packages is %s - not adding any install instructions", toString(pkgs))
    return(base_dockerfile)
  }

  package_reqs <- character(0)

  # 0. Check if packages can be left out because they are pre-installed for given image
  image_name <- base_dockerfile@image@image
  if (filter_baseimage_pkgs && !versioned_packages) {
    image <- docker_arguments(base_dockerfile@image)

    no_log <- capture.output(available_pkgs <- get_installed_packages(image = image)$pkg)
    futile.logger::flog.debug("Detected packages: %s", toString(no_log))

    cran_packages <- pkgs[stringr::str_detect(string = pkgs$source, pattern = "CRAN"),]
    skipable <- cran_packages$name %in% available_pkgs
    skipped_str <- toString(stringr::str_sort((as.character(cran_packages[skipable,]$name))))
    futile.logger::flog.info("Skipping packages for image %s (packages are unversioned): %s",
                             image, skipped_str)

    if (any(skipable))
      addInstruction(base_dockerfile) <- Comment(text = paste0("CRAN packages skipped because they are in the base image: ",
                                                        skipped_str))

    # do not add skippable, add all non-CRAN packages
    pkgs <- rbind(cran_packages[!skipable,], pkgs[pkgs$source != "CRAN",])
  }

  # 0. Installing github packages requires the package 'remotes' (and devtools for R < 3.4, which is not suppoted), see https://github.com/eddelbuettel/littler/blob/master/inst/examples/installGithub.r#L12
  if (nrow(pkgs[pkgs$source == "github",]) > 0 && !"remotes" %in% pkgs$name) {
    pkgs <- rbind(pkgs, remotes = data.frame(name = "remotes", version = "1.1.1", source = "CRAN"))
    futile.logger::flog.debug("Added package 'remotes' to package list to be able to install from GitHub")
  }

  if (is.null(platform)) {
    warning("Platform could not be detected, proceed at own risk.")
  } else if (!isTRUE(platform %in% .supported_platforms)) {
    warning("The determined platform '", platform,
            "' is currently not supported for handling system dependencies. Therefore, the created manifests might not work.")
  }

  if (nrow(pkgs) > 0) {
    # 1. get system dependencies if packages must be installed (if applicable by given platform)
    package_reqs <- sapply(X = stringr::str_sort(as.character(unlist(pkgs$name))),
                           FUN = .find_system_dependencies,
                           platform = platform,
                           soft = soft,
                           offline = offline)
    package_reqs <- unlist(package_reqs)

    # selected known dependencies that can be left out because they are pre-installed for given image
    if (filter_deps_by_image) {
      skipable <- .skipable_deps(image_name)
      package_reqs <- package_reqs[!package_reqs %in% skipable]
      futile.logger::flog.info("Skipping deps for image %s: %s", image_name, toString(skipable))
    }

    # remove duplicate system requirements and sort (to increase own reproducibility)
    package_reqs <- stringr::str_sort(unique(package_reqs))

    # if platform is debian and system dependencies need to be installed, add the commands
    if (length(package_reqs) > 0) {
      if (platform == .debian_platform) {
        commands <- "export DEBIAN_FRONTEND=noninteractive; apt-get -y update"
        install_command <- paste("apt-get install -y",
                                 paste(package_reqs, collapse = " \\\n\t"))
        commands <- append(commands, install_command)
        addInstruction(base_dockerfile) <- Run_shell(commands)
      } else {
        warning("Platform ", platform, " not supported, cannot add installation commands for system requirements.")
      }
    } else {
      futile.logger::flog.debug("No system requirements found that must be installed")
    }

    if (versioned_packages) {
      futile.logger::flog.info("Versioned packages enabled, installing 'versions'")
      addInstruction(base_dockerfile) <- Run("install2.r", "versions")
    }

    # 2. add installation instruction for CRAN packages
    pkgs_cran <- pkgs[stringr::str_detect(string = pkgs$source, pattern = "CRAN"),]
    if (nrow(pkgs_cran) > 0) {
      if (versioned_packages) {
        futile.logger::flog.info("Adding versioned CRAN packages: %s", toString(pkgs_cran$name))
        addInstruction(base_dockerfile) <- versioned_install_instructions(pkgs_cran)
      } else {
        cran_packages <- stringr::str_sort(as.character(unlist(pkgs_cran$name))) # sort, to increase own reproducibility
        futile.logger::flog.info("Adding CRAN packages: %s", toString(cran_packages))
        addInstruction(base_dockerfile) <- Run("install2.r", cran_packages)
      }
    } else futile.logger::flog.debug("No CRAN packages to add.")

    # 3. add installation instruction for Bioconductor packages
    pkgs_bioc <- pkgs[stringr::str_detect(string = pkgs$source, pattern = "Bioconductor"),]
    if (nrow(pkgs_bioc) > 0) {
      if (versioned_packages) {
        futile.logger::flog.warn("Adding versioned Bioconductor packages not supported: %s", toString(pkgs_bioc$name))
      }

      bioc_packages <- stringr::str_sort(as.character(unlist(pkgs_bioc$name))) # sort, to increase own reproducibility
      futile.logger::flog.info("Adding Bioconductor packages: %s", toString(bioc_packages))
      repos = as.character(BiocManager::repositories())
      addInstruction(base_dockerfile) <- Run("install2.r", params = c(sprintf("-r %s -r %s -r %s -r %s",
                                                                         repos[1], repos[2],
                                                                         repos[3], repos[4]),
                                                                 bioc_packages))
    } else futile.logger::flog.debug("No Bioconductor packages to add.")

    # 4. add installation instruction for GitHub packages
    pkgs_gh <- pkgs[stringr::str_detect(string = pkgs$source, stringr::regex("GitHub", ignore_case = TRUE)),]
    if (nrow(pkgs_gh) > 0) {
      github_packages <- stringr::str_sort(as.character(unlist(pkgs_gh$version))) # sort, to increase own reproducibility
      futile.logger::flog.info("Adding GitHub packages: %s", toString(github_packages))
      addInstruction(base_dockerfile) <- Run("installGithub.r", github_packages)
    }
  } else {
    futile.logger::flog.debug("No packages found that must be installed")
  }

  return(base_dockerfile)
}

#' Helper function for installing versioned R packages
#'
#' Based on \pkg{versions}.
#'
#' @param pkgs A \code{data.frame} with columns \code{name} and \code{version}
#' @return A list of objects of class \code{Run}: one with versioned installs based on \pkg{versions}, (optionally) one with unversioned installs of packages without version information (e.g. local packages).
#' @importFrom versions install.versions
versioned_install_instructions <- function(pkgs) {
  pkgs_sorted <- pkgs[order(pkgs$name),] # sort, to increase own reproducibility

  installInstructions <- apply(X = pkgs_sorted,
                               FUN = function(pkg) {
                                 ifelse(!is.na(pkg["version"]),
                                        paste0('versions::install.versions(\'', pkg["name"], '\', \'' , pkg["version"], '\')'),
                                        NA)
                                 },
                               MARGIN = 1)
  installInstructions <- installInstructions[!is.na(installInstructions)]

  params <- c(rbind(rep("-e", length(installInstructions)), installInstructions))
  instructions <- list(Run(exec = "Rscript", params = params))

  if (any(is.na(pkgs_sorted$version))) {
    unversioned <- pkgs_sorted[is.na(pkgs_sorted$version),]
    unversioned <- stringr::str_sort(as.character(unlist(unversioned$name))) # sort, to increase own reproducibility
    futile.logger::flog.warn("No version information found for packages: %s", toString(unversioned))
    instructions <- c(Run("install2.r", unversioned), instructions)
  }
  return(instructions)
}

.find_system_dependencies <- function(package,
                                      platform,
                                      soft = TRUE,
                                      offline = FALSE,
                                      package_version = as.character(utils::packageVersion(package))) {
  method = NA
  if (offline)
    method = "sysreq-package"
  else
    method = "sysreq-api"

  .dependencies <- NA

  futile.logger::flog.info("Going online? %s  ... to retrieve system dependencies (%s)", !offline, method)
  futile.logger::flog.debug("Retrieving sysreqs for %s packages and platform %s: %s", length(package), platform, toString(package))

  # slower, because it analyzes all package DESCRIPTION files of attached / loaded packages.
  # That causes an overhead of database-requests, because dependent packages appear in the sessionInfo as well as in the DESCRIPTION files
  if (method == "sysreq-package") {
    .dependencies <- .find_by_sysreqs_pkg(
      package = package,
      package_version = package_version,
      platform = platform,
      soft = soft
    )
  }

  # faster, but only finds direct package dependencies from all attached / loaded packages
  if (method == "sysreq-api") {
    .dependencies <- .find_by_sysreqs_api(package = package, platform = platform)

    if (length(.dependencies) > 0) {
      # remove duplicates and unlist dependency string from sysreqs
      .dependencies <- unique(unlist(.dependencies, use.names = FALSE))
      .dependencies <- unlist(lapply(.dependencies, function(x) {
        unlist(strsplit(x, split = " "))
      }))
    }
  }

  futile.logger::flog.debug("Found %s system dependencies: %s", length(.dependencies), toString(.dependencies))
  return(.dependencies)
}

.find_by_sysreqs_pkg <- function(package,
                                 platform,
                                 soft = TRUE,
                                 package_version,
                                 localFirst = TRUE) {
  # for more than one package:
  if (length(package) > 1) {
    out <- mapply(function(pkg, version) {
      .find_by_sysreqs_pkg(pkg, platform, soft, version, localFirst)
    }, pkg = package, version = package_version)
    return(out) # there might be dublicate dependencies, they must be removed by the invoking method
  }

  sysreqs <- character(0)
  if (localFirst) {
    futile.logger::flog.info(
      "Trying to determine system requirements for package '%s' from the local DESCRIPTION file",
      package
    )
    path <- find.package(package, quiet = TRUE)
    if (is.null(path) ||
        length(path) == 0 ||
        utils::packageVersion(package) != package_version) {
      futile.logger::flog.warn(
        "No matching package DESCRIPTION found locally for package '",
        package,
        "', version '",
        package_version,
        "' ."
      )
    } else{
      sysreqs <- NA
      if (is.null(platform)) {
        futile.logger::flog.warn("Platform could not be determined, possibly because of unknown base image.",
                                 " Using '%s'", sysreqs::current_platform())
        sysreqs <-
          sysreqs::sysreqs(file.path(path, "DESCRIPTION"),
                           soft = soft)
      } else {
        sysreqs <-
          sysreqs::sysreqs(file.path(path, "DESCRIPTION"),
                           platform = platform,
                           soft = soft)
      }
      return(sysreqs)
    }
  }

  futile.logger::flog.info("Trying to determine system requirements for '%s' from the DESCRIPTION file on CRAN",
                           package)

  con <- url(paste0("https://CRAN.R-project.org/package=",
                    package,
                    "/DESCRIPTION"))
  temp <- tempfile()
  success <- TRUE
  tryCatch({
    desc <- readLines(con)
    writeLines(desc, temp)
    sysreqs <-
      sysreqs::sysreqs(temp, platform = platform, soft = soft)
  }, error = function(e) {
    success <- FALSE
    futile.logger::flog.debug("Error requesting system requirements from DESCRIPTION file on CRAN: %s", toString(e))
  },
  finally = {
    unlink(temp)
    close(con)
  })

  if (!success) {
    warning("Could not package DESCRIPTION for package '",
            package,
            ", on CRAN. containerit failed to determine system requirements.")
    return(NULL)
  } else {
    return(sysreqs)
  }

}

.find_by_sysreqs_api <- function(package, platform) {
  # calls like e.g. https://sysreqs.r-hub.io/pkg/rgdal,curl,rmarkdown/linux-x86_64-ubuntu-gcc are much faster than doing separate calls for each package
  if (length(package) > 0) {
    package = paste(package, collapse = ",")
  }

  futile.logger::flog.info("Trying to determine system requirements for the package(s) '%s' from sysreqs online DB", package)

  .url <- paste0("https://sysreqs.r-hub.io/pkg/", package, "/", platform)
  con <- url(.url)
  futile.logger::flog.debug("Accessing '%s'", .url)
  success <- TRUE
  desc <- NULL

  tryCatch({
    desc <- readLines(con, warn = FALSE)
    futile.logger::flog.debug("Response: %s", toString(desc))
    parser <- rjson::newJSONParser()
    parser$addData(desc)
    desc <- as.character(parser$getObject())
    desc <- desc[!desc == "NULL"]
  }, error = function(e) {
    success <- FALSE
    futile.logger::flog.debug("Error requesting package info from sysreqs online DB: %s", toString(e))
  }, finally = close(con))

  if (!success) {
    warning("Containerit failed to determine system requriements for package ",
            package, "using sysreq online API")
  }

  futile.logger::flog.debug("Dependencies info from sysreqs online DB:\n%s", toString(desc))
  return(desc)
}

#' Get GitHub reference from package
#'
#' If a package is installed from GitHub this function tries to retrieve the reference (i.e. user name, repository name, and commit) from
#' (a) the provided sessionInfo, or
#' (b) locally, and only if the package is installed (!), using \code{\link[devtools]{session_info}}.
#'
#' @param pkg The name of the package to retrieve the reference for
#' @param pkgs Lists of packages from a sessionInfo object
#'
#' @return A character string with a short refernce, e.g. \code{r-hub/sysreqs@481d263}, \code{NA} is nothign could be found
#' @export
#'
#' @examples
#' \dontrun{
#' getGitHubRef(rsysreqs)
#' }
#'
getGitHubRef = function(pkg, pkgs = c(sessionInfo()$otherPkgs, sessionInfo()$loadedOnly)) {
  ref <- NA_character_

  if (!is.null(pkgs[[pkg]]$GithubRepo))
    repo <- pkgs[[pkg]]$GithubRepo
  else repo <- pkgs[[pkg]]$RemoteRepo

  if (!is.null(pkgs[[pkg]]$GithubUsername))
    uname <- pkgs[[pkg]]$GithubUsername
  else uname <- pkgs[[pkg]]$RemoteUsername

  if (!is.null(pkgs[[pkg]]$GithubSHA1))
    ghr <- pkgs[[pkg]]$GithubSHA1
  else ghr <- pkgs[[pkg]]$RemoteSha

  if (any(sapply(X = c(repo, uname, ghr), FUN = is.null))) {
    futile.logger::flog.warn("Exact reference of GitHub package %s could not be determined from session info: %s %s %s",
                             pkg, repo, uname, ghr)
  } else {
    ref = paste0(uname, "/", repo, "@", ghr)
  }

  if (is.na(ref)) {
    if (requireNamespace(pkg))
      #try to determine github reference from devools
      si_devtools <- devtools::session_info()
    ref_devtools <- si_devtools$packages$source[si_devtools$packages$package == pkg]
    futile.logger::flog.debug("Looking for references with devtools for package %s", ref_devtools)

    if (stringr::str_detect(ref_devtools, "(?i)^GitHub \\(.*/.*@|#.*\\)$")) {
      ref_devtools <- stringr::str_replace(ref_devtools, "(?i)^GitHub \\(", replacement = "")
      ref_devtools <- stringr::str_replace(ref_devtools, "\\)$", replacement = "")
      futile.logger::flog.debug("GitHub reference for %s found with devtools: %s",
                                pkg,
                                ref_devtools)
      ref <- ref_devtools
    } else
      futile.logger::flog.warn("GitHub ref is unknown, but package %s is not available locally, no fallback.", pkg)
  }
  return(ref)
}

