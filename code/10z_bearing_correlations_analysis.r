{ # Load required libraries
    library(tidyverse)
    library(circular)
    library(geosphere)
    library(lubridate)
    library(conflicted)
    library(mgcv)
    library(psych)
    library(Hmisc)
    library(sf)
    conflicts_prefer(dplyr::summarise, dplyr::filter, dplyr::lag, purrr::map, .quiet = TRUE)

    # Calculate bearings function
    calculate_bearings <- function(data) {
        data %>%
            mutate(bearing = bearing(cbind(lon, lat), cbind(lead(lon), lead(lat))))
    }

    # Main analysis function
    run_analysis <- function(seal_data, particle_data) {
        cat("Starting run_analysis function\n")

        # Calculate bearings
        cat("Calculating bearings for seal data\n")
        seal_bearings <- calculate_bearings(seal_data)
        cat("Calculating bearings for particle data\n")
        particle_bearings <- calculate_bearings(particle_data)

        cat("Starting cumulative circular correlation calculation\n")
        # Calculate cumulative circular correlation
        cumulative_correlations <- seal_bearings %>%
            left_join(particle_bearings, by = c("id", "days_since_start"), suffix = c("_seal", "_particle")) %>%
            group_by(id) %>%
            arrange(id, days_since_start) %>%
            mutate(
                cumulative_correlation = map(seq_along(bearing_seal), function(i) {
                    circular::cor.circular(
                        circular::circular(bearing_seal[1:i], units = "degrees", type = "directions", template = "geographics", modulo = "2pi", rotation = "clock"),
                        circular::circular(bearing_particle[1:i], units = "degrees", type = "directions", template = "geographics", modulo = "2pi", rotation = "clock"),
                        test = TRUE
                    )
                })
            ) %>%
            rowwise() %>%
            mutate(
                cor = cumulative_correlation$cor,
                p_value = cumulative_correlation$p.value,
                statistic = cumulative_correlation$statistic
            ) %>%
            select(-cumulative_correlation) %>%
            ungroup()

        cat("Finished cumulative circular correlation calculation\n")

        cat("Finding critical period\n")
        # Find critical period
        critical_period <- cumulative_correlations %>%
            filter(days_since_start > 1) %>%
            group_by(id) %>%
            summarise(
                max_correlation = max(cor, na.rm = TRUE),
                days_to_max = days_since_start[which.max(cor)] %>% as.numeric()
            )

        cat("Performing t-test\n")
        # Test if the mean maximum correlation is significantly different from 0
        t_test_result <- t.test(critical_period$max_correlation)

        cat("Performing correlation test\n")
        # Correlation test
        correlation_test <- cor.test(critical_period$days_to_max, critical_period$max_correlation)

        cat("Preparing data for GAMM model\n")
        # GAMM model
        mod_dat <- cumulative_correlations %>%
            mutate(
                days_since_start = as.numeric(days_since_start),
                id = as.factor(id)
            ) %>%
            filter(!is.na(cor))

        cat("Fitting GAMM model\n")
        gamm_model <- gamm(cor ~ s(days_since_start, k = 10) + s(id, bs = "re"),
            data = mod_dat,
            method = "REML"
        )
        cat("GAMM model fitting complete\n")

        cat("run_analysis function completed\n")
        # Return results
        list(
            seal_bearings = seal_bearings,
            particle_bearings = particle_bearings,
            cumulative_correlations = cumulative_correlations,
            critical_period = critical_period,
            t_test_result = t_test_result,
            correlation_test = correlation_test,
            gamm_model = gamm_model
        )
    }

    # Function to generate all plots
    generate_plots <- function(results) {
        plot_list <- list()

        # Bearings over time plot
        plot_list$bearings_over_time <- ggplot() +
            geom_point(data = results$seal_bearings, aes(x = days_since_start, y = bearing), color = "red", size = 0.5) +
            geom_point(data = results$particle_bearings, aes(x = days_since_start, y = bearing), color = "blue", size = 0.5) +
            theme_minimal() +
            facet_wrap(~id, scales = "free") +
            theme(legend.position = "none") +
            labs(
                title = "Bearings over Time for Seals and Particles",
                x = "Days Since Start",
                y = "Bearing (degrees)",
                caption = "Red = Seals, Blue = Particles"
            )

        # Lat and Lon plot with path arrows
        plot_list$lat_lon_arrows <- ggplot() +
            geom_point(data = results$seal_bearings, aes(x = lon, y = lat), size = 0.5) +
            geom_segment(
                data = results$seal_bearings,
                aes(
                    x = lon, y = lat,
                    xend = lead(lon), yend = lead(lat)
                ),
                color = "red", arrow = arrow(length = unit(0.2, "cm"))
            ) +
            theme_minimal() +
            facet_wrap(~id, scales = "free") +
            theme(legend.position = "none") +
            labs(
                title = "Lat and Lon for Seals with Path Arrows",
                x = "Longitude",
                y = "Latitude"
            )

        # Cumulative correlations plot
        plot_list$cumulative_correlations <- ggplot(results$cumulative_correlations, aes(x = days_since_start, y = cor)) +
            geom_line() +
            theme_minimal() +
            lims(y = c(-1, 1)) +
            facet_wrap(~id, scales = "free") +
            labs(
                title = "Cumulative Correlation of Bearings between Seals and Particles",
                x = "Days Since Start",
                y = "Cumulative Correlation"
            )

        # Histogram of correlations
        plot_list$correlation_histogram <- ggplot(results$cumulative_correlations, aes(x = cor)) +
            geom_histogram(binwidth = 0.05, fill = "blue", alpha = 0.7) +
            theme_minimal() +
            labs(
                title = "Distribution of Correlations",
                x = "Correlation", y = "Count"
            )

        # Maximum correlation distribution
        plot_list$max_correlation_histogram <- ggplot(results$critical_period, aes(x = max_correlation)) +
            geom_histogram(binwidth = 0.05, fill = "blue", alpha = 0.7) +
            theme_minimal() +
            labs(
                title = "Distribution of Maximum Correlations",
                x = "Maximum Correlation", y = "Count"
            )

        # Maximum correlation vs time to max
        plot_list$max_cor_vs_time <- ggplot(results$critical_period, aes(x = days_to_max, y = max_correlation)) +
            geom_point() +
            geom_smooth(method = "lm") +
            theme_minimal() +
            labs(
                title = "Maximum Correlation vs. Time to Max Correlation",
                x = "Days to Max Correlation", y = "Maximum Correlation"
            )

        plot_list
    }

    # Main execution function
    main <- function(seal_data_path, particle_data_path, output_path) {
        tryCatch(
            {
                # Create a new folder with the current date
                dir.create(output_path, showWarnings = FALSE, recursive = TRUE)

                # Start capturing console output
                sink(file.path(output_path, "console_output.txt"))

                # Print the paths being used
                cat("Seal data path:", seal_data_path, "\n")
                cat("Particle data path:", particle_data_path, "\n")
                cat("Output path:", output_path, "\n\n")

                # Load data
                cat("Loading seal data\n")
                locw <- readRDS(seal_data_path)


                cat("Loading particle data\n")
                locpt <- readRDS(particle_data_path)


                cat("Preprocessing particle data\n")
                locpt <- locpt %>% mutate(date = with_tz(date, tzone = "UTC"))

                cat("Preprocessing seal data\n")
                # Add this line to convert the spatial object to a regular dataframe
                locw <- locw %>% st_drop_geometry()

                # Data preprocessing
                locpt <- locpt %>% mutate(date = with_tz(date, tzone = "UTC"))

                # Identify and remove seals with no weanmass data
                all_data_weaners <- readRDS("./Output/all_data_combined.rds")
                seals_with_no_weanmass <- all_data_weaners %>%
                    group_by(id) %>%
                    summarise(weanmass = mean(weanmass, na.rm = TRUE)) %>%
                    filter(is.na(weanmass)) %>%
                    pull(id)

                # Prepare locw data
                locw <- locw %>%
                    filter(!id %in% seals_with_no_weanmass) %>%
                    filter(trip == 1, SUS == FALSE) # only keep first trip

                # Resample data function
                resample_data <- function(df, interval = "1 day") {
                    if ("sf" %in% class(df)) {
                        cat("Converting spatial object to dataframe\n")
                        df <- df %>% st_drop_geometry()
                    }
                    df %>%
                        mutate(date = floor_date(date, unit = interval)) %>%
                        group_by(id, date) %>%
                        summarise(across(everything(), ~ mean(.x, na.rm = TRUE))) %>%
                        ungroup()
                }

                # Resample both datasets
                locpt_resampled <- resample_data(locpt, interval = "1 day")
                cat("Resampling seal data\n")
                locw_resampled <- locw %>%
                    select(id, date, lat, lon) %>%
                    resample_data(interval = "1 day")

                # Match date range function
                match_date_range <- function(df1, df2) {
                    df1 %>%
                        inner_join(df2 %>% select(id, date), by = c("id", "date"))
                }

                locpt_matched <- match_date_range(locpt_resampled, locw_resampled)
                locw_matched <- match_date_range(locw_resampled, locpt_resampled)

                # Calculate days since start
                locpt_matched <- locpt_matched %>%
                    group_by(id) %>%
                    mutate(days_since_start = difftime(date, min(date), units = "day"))
                locw_matched <- locw_matched %>%
                    group_by(id) %>%
                    mutate(days_since_start = difftime(date, min(date), units = "day"))

                # Ensure both dataframes have the same number of rows per id
                stopifnot(all(table(locpt_matched$id) == table(locw_matched$id)))

                # Sort both dataframes by id and date to ensure alignment
                locpt_matched <- locpt_matched %>% arrange(id, date)
                locw_matched <- locw_matched %>% arrange(id, date)

                # Run analysis
                results <- run_analysis(seal_data = locw_matched, particle_data = locpt_matched)

                # Generate plots
                plots <- generate_plots(results)

                # Print summary statistics and test results
                print("Summary of critical period:")
                print(psych::describe(results$critical_period))
                print(Hmisc::describe(results$critical_period))

                print("T-test results (if p < 0.05, then the mean maximum correlation is significantly different from 0):")
                print(results$t_test_result)

                print("Correlation test results (if p < 0.05, then the correlation is significantly different from 0):")
                print(results$correlation_test)

                print("GAMM model summary:")
                print(summary(results$gamm_model$gam))

                ## Save model plots
                png(file.path(output_path, "gamm_model_plots.png"), width = 6, height = 3.5, units = "in", res = 300, pointsize = 6)
                par(mfrow = c(2, 2))
                plot(results$gamm_model$gam, all.terms = TRUE, pages = 1)
                dev.off()

                # Combine all results
                all_results <- list(
                    data = list(
                        locw_matched = locw_matched,
                        locpt_matched = locpt_matched
                    ),
                    analysis_results = results,
                    plots = plots,
                    input_paths = list(
                        seal_data_path = seal_data_path,
                        particle_data_path = particle_data_path
                    )
                )

                # Save all results
                saveRDS(all_results, file.path(output_path, "all_results.rds"))

                # Save plots as individual files
                for (plot_name in names(plots)) {
                    ggsave(file.path(output_path, paste0(plot_name, ".png")), plots[[plot_name]], width = 10, height = 8, bg = "white")
                }

                # Stop capturing console output
                sink()

                # Print a message to confirm completion
                cat("Analysis complete. Results saved to", output_path, "\n")
            },
            error = function(e) {
                cat("Error occurred:", conditionMessage(e), "\n")
                print("In:")
                print(conditionCall(e))
                print(rlang::last_trace())
            }
        )
    }

    # Execute the main function
    current_date <- format(Sys.Date(), "%Y-%m-%d")
    output_path <- file.path("./Output/cumulative_correlation_analysis", current_date)

    main(
        seal_data_path = "./Output/tracks_processed_12h.rds",
        particle_data_path = "./Output/currently_particleTrace.rds",
        output_path = output_path
    )
}