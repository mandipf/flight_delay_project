# import libraries -----

library(tidyverse)
library(here)
library(janitor)
library(geosphere)


# import datasets -----

airlines_df <- read_csv(here("data/raw_data/airlines.csv"))
airports_df <- read_csv(here("data/raw_data/airports.csv"))
flights_df <- read_csv(here("data/raw_data/flights.csv"))
planes_df <-  read_csv(here("data/raw_data/planes.csv"))
weather_df <- read_csv(here("data/raw_data/weather.csv"))
noaa_weather_df <- read_csv(here("data/raw_data/weather_noaa_ghcnd.csv"))
meteostat_ewr <- read_csv(here("data/raw_data/weather_meteostat_ewr.csv"))
meteostat_jfk <- read_csv(here("data/raw_data/weather_meteostat_jfk.csv"))
meteostat_lga <- read_csv(here("data/raw_data/weather_meteostat_lga.csv"))


# flight data wrangling (completed and cancelled flights) -----

flights_final <- flights_df %>% 
  # create a single date/time reference for each flight
  mutate(sch_departure = ISOdate(year, month, day, hour, minute),
         .before = year) %>%
  # add extra time periods to filter/search for
  mutate(wday = wday(sch_departure),
         cycle = case_when(hour >= 5 & hour < 12 ~ "Morning",
                           hour >= 12 & hour < 17 ~ "Afternoon",
                           hour >= 17 & hour < 21 ~ "Evening",
                           .default = "Night"),
         .after = month) %>% 
  # create a column for joining with additional weather datasets
  mutate(date = as.Date(paste(year, month, day), "%Y%m%d"),
         .before = year) %>% 
  # set rows with valid departure time and NA delay as zero delay
  mutate(dep_delay = case_when(is.na(dep_time) ~ NA, # cancelled flight
                               is.na(dep_delay) ~ 0, # no delay
                               dep_delay < 0 ~ 0, # leaving early is no delay
                               .default = dep_delay),
         delay_flag = case_when(is.na(dep_time) ~ "Cancelled",
                                dep_delay < 15 ~ "No",
                                .default = "Yes")) %>%
  # add variables for how busy airport/flight schedule is
  mutate(flights_per_day = n(), .by = date) %>% 
  mutate(flights_per_hour = n(), .by = time_hour) %>% 
  # extract only the columns required for final analysis
  select(sch_departure, month, wday, hour, cycle, 
         origin, dest, dep_delay, delay_flag,
         carrier, flight, tailnum, distance,
         flights_per_day, flights_per_hour, time_hour, date)


# original weather data wrangling -----

weather_final <- weather_df %>% 
  select(origin, time_hour, wind_dir, wind_speed, wind_gust, visib)


# noaa weather data wrangling -----

noaa_weather_final <- noaa_weather_df %>% 
  clean_names() %>% 
  # create FAA airport code to join with original weather dataset
  mutate(origin = case_when(str_starts(name, "LAG") ~ "LGA",
                            str_starts(name, "JFK") ~ "JFK", 
                            .default = "EWR")) %>% 
  select(date, origin, tavg, prcp, snow, snwd)


# meteostat weather data wrangling -----

# combine all three datasets and set airport abbreviation as "origin" column
meteostat_weather_df <- bind_rows(
  list(
    "EWR" = meteostat_ewr,
    "JFK" = meteostat_jfk,
    "LGA" = meteostat_lga
  ),
  .id = "origin"
)

meteostat_weather_final <- meteostat_weather_df %>%
  mutate(week = isoweek(ymd(meteostat_weather_df$date))) %>% 
  # impute missing values with median value from that week (per airport)
  mutate(pres = coalesce(pres, round(median(pres, na.rm= TRUE), 1)),
         .by = c(origin, week)) %>%
  select(date, origin, pres)


# airline data wrangling -----

airlines_final <- airlines_df %>% 
  mutate(name = str_remove(name, " Inc.$| Co.$"))


# airport data wrangling (add missing airports) -----

extra_airports <- tibble(
  faa = c("BQN", "PSE", "SJU", "STT"),
  lat = c(18.470200, 17.997200, 18.290560, 18.335197),
  lon = c(-67.079224, -66.563919, -67.145058, -64.971583)
)

airports_final <- airports_df %>% 
  select(faa, lat, lon) %>% 
  bind_rows(extra_airports)


# plane data wrangling -----

planes_final <- planes_df %>% 
  mutate(year = if_else(year != 0, year, NA))


# join all final datasets -----

final_df <- flights_final %>% 
  left_join(weather_final, by = c("origin", "time_hour")) %>%
  left_join(noaa_weather_final, by = c("origin", "date")) %>% 
  left_join(meteostat_weather_final, by = c("origin", "date")) %>%
  left_join(airports_final, by = join_by("origin" == "faa")) %>%
  left_join(airports_final, by = join_by("dest" == "faa")) %>%
  left_join(airlines_final, by = "carrier") %>%
  left_join(planes_final, by = "tailnum") %>% 
  # geosphere::bearing requires rowwise (and ungroup) to add plane direction
  rowwise() %>%
  mutate(nose_dir = bearing(c(lon.x, lat.x), c(lon.y, lat.y))) %>%
  ungroup() %>%
  # convert (-180 to 180) to (0 to 360)
  mutate(nose_dir = (nose_dir + 360) %% 360) %>%
  # impute missing wind data with median value from that day (per airport)
  mutate(wind_dir = coalesce(wind_dir, round(median(wind_dir, na.rm= TRUE), 0)),
         wind_speed = coalesce(wind_speed, median(wind_speed, na.rm= TRUE)),
         wind_gust = coalesce(wind_gust, median(wind_gust, na.rm= TRUE)),
         visib = coalesce(visib, round(median(visib, na.rm= TRUE), 0)),
         .by = c(origin, date)) %>%
  mutate(carrier = name) %>%
  select(sch_departure, month, wday, hour, cycle, # time
         flights_per_day, flights_per_hour, # airport schedule
         origin, dep_delay, delay_flag, # origin
         dest, distance, nose_dir, # destination
         carrier, type, seats, # airline/airplane
         wind_dir, wind_speed, visib, prcp, snow, snwd, tavg, pres) # weather


# export final dataset to CSV -----

final_df %>%
  write.csv(file = here("data/clean_data/flight_delay_clean.csv"),
            row.names = FALSE)

