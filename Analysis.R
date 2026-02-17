# ==========================================
# 1. THE ENVIRONMENT
# ==========================================
library(readxl)
library(tidyverse)
library(zoo)
library(sf)
library(spdep)
library(plm)
library(splm)
# ==========================================
# 2. DATA IMPORT & CLEANING
# ==========================================
target_file <- "rice_raw.csv.xlsx"
raw_data <- read_excel(target_file, skip = 2)

months_base <- c("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "Annual")
years_base <- 2016:2025
full_header <- c("Province", "Commodity", paste(rep(years_base, each = 13), months_base, sep = "_"))
colnames(raw_data) <- full_header[1:ncol(raw_data)]

clean_rice <- raw_data %>%
  slice(-1) %>%
  mutate(Province = gsub("\\.", "", Province)) %>%
  filter(!grepl("PHILIPPINES|REGION|NCR|CAR|MIMAROPA|NIR|BARMM", Province)) %>%
  pivot_longer(cols = contains("_"), names_to = "Date_Raw", values_to = "Price") %>%
  mutate(Price = as.numeric(ifelse(Price == "..", NA, Price))) %>%
  filter(!grepl("Annual", Date_Raw)) %>%
  # DO NOT drop_na(Price) here. We need the rows for imputation.
  mutate(
    Date = as.yearmon(Date_Raw, "%Y_%b"),
    Post = ifelse(Date >= as.yearmon("Mar 2019"), 1, 0),
    Join_Key = toupper(gsub("[[:space:]]", "", Province))
  )

# ==========================================
# 3. TREATMENT & IMPUTATION (BALANCING)
# ==========================================
rcef_list <- c(
  "IFUGAO", "KALINGA", "ILOCOSNORTE", "ILOCOSSUR", "LAUNION", "PANGASINAN",
  "CAGAYAN", "ISABELA", "NUEVAVIZCAYA", "QUIRINO", "AURORA", "BATAAN", "BULACAN",
  "NUEVAECIJA", "PAMPANGA", "TARLAC", "ZAMBALES", "BATANGAS", "CAVITE", "LAGUNA",
  "QUEZON", "OCCIDENTALMINDORO", "ORIENTALMINDORO", "PALAWAN", "MARINDUQUE",
  "ROMBLON", "ALBAY", "CAMARINESSUR", "MASBATE", "SORSOGON", "AKLAN", "ANTIQUE",
  "CAPIZ", "ILOILO", "NEGROSOCCIDENTAL", "BOHOL", "LEYTE", "NORTHERNSAMAR",
  "SAMAR", "ZAMBOANGADELSUR", "ZAMBOANGASIBUGAY", "BUKIDNON", "LANAODELNORTE",
  "MISAMISOCCIDENTAL", "DAVAODELNORTE", "DAVAODELSUR", "NORTHCOTABATO",
  "SOUTHCOTABATO", "SULTANKUDARAT", "AGUSANDELNORTE", "AGUSANDELSUR",
  "SURIGAODELSUR", "MAGUINDANAO"
)

# Impute and create the final balanced dataframe
p_data_final <- clean_rice %>%
  mutate(Treated = ifelse(Join_Key %in% rcef_list, 1, 0)) %>%
  group_by(Join_Key) %>%
  arrange(Date) %>%
  mutate(Price = na.approx(Price, na.rm = FALSE)) %>% 
  fill(Price, .direction = "downup") %>%
  ungroup() %>%
  drop_na(Price) # Only drops provinces that are 100% empty

# ==========================================
# 3.5 LOAD & FORCE GADM GEOMETRY
# ==========================================
# Logic: GADM JSONs often have invalid self-intersections. 
# st_make_valid() and st_as_sf() are non-negotiable here.
province_shapes <- st_read("gadm41_PHL_1.json", quiet = TRUE) %>%
  st_as_sf() %>%
  st_make_valid() %>%
  mutate(Join_Key = toupper(gsub("[[:space:]]", "", NAME_1)))

# FORCE THE CRS: If it's missing, we manually anchor it to WGS84
if (is.na(st_crs(province_shapes))) {
  st_crs(province_shapes) <- 4326
}

# ==========================================
# 4. INTEGRATE SPATIAL DATA (SYSTEM OVERRIDE)
# ==========================================
# 1. Kill the S2 engine to prevent transformation crashes
sf_use_s2(FALSE)

# 2. Sync tabular data and shapes
common_provinces <- intersect(unique(p_data_final$Join_Key), unique(province_shapes$Join_Key))

p_data_final <- p_data_final %>% 
  filter(Join_Key %in% common_provinces) %>% 
  arrange(Join_Key, Date)

province_shapes_sync <- province_shapes %>% 
  filter(Join_Key %in% common_provinces) %>% 
  arrange(Join_Key)

# 3. CALCULATE COORDINATES (PLANAR BYPASS)
# Logic: By pulling the geometry into a separate object and using of_geography = FALSE,
# we bypass the internal 'st_transform' check that is causing your crash.
clean_geom <- st_geometry(province_shapes_sync)
coords_sync <- suppressWarnings(st_coordinates(st_centroid(clean_geom, of_geography = FALSE)))

# 4. GENERATE WEIGHTS (k=3 Neighbors)
lw_sync <- nb2listw(knn2nb(knearneigh(coords_sync, k = 3)), style = "W")

# --- VISUAL PROOF ---
# This proves the centroids were successfully calculated.
plot(st_geometry(province_shapes_sync), border="gray80", main="Spatial Audit: Connectivity Active")
points(coords_sync, col="red", pch=20, cex=0.6)

# ==========================================
# 4.5 DIAGNOSTICS: PARALLEL TRENDS & MORAN'S I
# ==========================================

# A. PARALLEL TRENDS PLOT
# -----------------------
trend_summary <- p_data_final %>%
  group_by(Date, Treated) %>%
  summarise(Avg_Price = mean(Price, na.rm = TRUE), .groups = 'drop') %>%
  mutate(Group = ifelse(Treated == 1, "RCEF (Treated)", "Non-RCEF (Control)"))

ggplot(trend_summary, aes(x = as.Date(Date), y = Avg_Price, color = Group)) +
  geom_line(size = 1) +
  geom_vline(xintercept = as.Date(as.yearmon("Mar 2019")), 
             linetype = "dashed", color = "red") +
  theme_minimal() +
  labs(title = "Parallel Trends: Farmgate Rice Prices",
       x = "Year", y = "Average Price (PHP/kg)")

# B. MORAN'S I (PRE-POLICY 2017)
# -----------------------
# Testing clustering before the RTL implementation
pre_2017 <- p_data_final %>%
  filter(format(Date, "%Y") == "2017") %>%
  group_by(Join_Key) %>%
  summarise(Avg_2017 = mean(Price)) %>%
  arrange(Join_Key) # Must match order of lw_sync

moran_pre <- moran.test(pre_2017$Avg_2017, lw_sync)
print("--- Moran's I: 2017 (Pre-Policy) ---")
print(moran_pre)

# C. MORAN'S I (POST-POLICY 2025)
# -----------------------
post_2025 <- p_data_final %>%
  filter(format(Date, "%Y") == "2025") %>%
  group_by(Join_Key) %>%
  summarise(Avg_2025 = mean(Price)) %>%
  arrange(Join_Key)

moran_post <- moran.test(post_2025$Avg_2025, lw_sync)
print("--- Moran's I: 2025 (Post-Policy) ---")
print(moran_post)

# ==========================================
# 5. THE SPATIAL DiD MODEL
# ==========================================
# Logic: Executing the SDiD with individual fixed effects and spatial lag.
p_final_panel <- pdata.frame(p_data_final, index = c("Join_Key", "Date"))

sdid_final <- spml(Price ~ Treated:Post, 
                   data = p_final_panel, 
                   listw = lw_sync, 
                   model = "within", 
                   effect = "individual", 
                   lag = TRUE)

summary(sdid_final)

# ==========================================
# 6. FINAL ASSET EXPORT (FOR GITHUB)
# ==========================================
# 1. Parallel Trends
trend_summary <- p_data_final %>%
  group_by(Date, Treated) %>%
  summarise(Avg_Price = mean(Price, na.rm = TRUE), .groups = 'drop') %>%
  mutate(Group = ifelse(Treated == 1, "RCEF (Treated)", "Non-RCEF (Control)"))

viz_trends <- ggplot(trend_summary, aes(x = as.Date(Date), y = Avg_Price, color = Group)) +
  geom_line(size = 1) +
  geom_vline(xintercept = as.Date(as.yearmon("Mar 2019")), linetype = "dashed", color = "red") +
  theme_minimal() + labs(title = "Audit: Parallel Trends")
ggsave("parallel_trends.png", viz_trends)

# 2. Spatial Residuals
p_data_final$resid <- residuals(sdid_final)
resids_spatial <- p_data_final %>% group_by(Join_Key) %>% summarise(Mean_Resid = mean(resid))
resid_map_data <- province_shapes_sync %>% left_join(resids_spatial, by = "Join_Key")

viz_resids <- ggplot(resid_map_data) +
  geom_sf(aes(fill = Mean_Resid)) +
  scale_fill_gradient2(low = "blue", mid = "white", high = "red") +
  theme_minimal() + labs(title = "Audit: Spatial Residuals")
ggsave("spatial_residuals.png", viz_resids)

message(">>> All Audits Complete. Results ready for submission.")
