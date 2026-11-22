# Solving Inventory Inefficiencies Using SQL

A PostgreSQL project that turns daily store sales and stock data into practical inventory decisions: what to reorder, how fast stock sells, how good the demand forecast is, and what actually drives sales.

---

## Project Overview

A retail business needs to avoid running out of stock without holding too much of it. This project builds a small database from raw sales data and uses SQL to answer:

1. Which store-products will run out before the next delivery, and how much should be ordered?
2. How quickly does stock turn over?
3. How accurate is the supplied demand forecast, and can it be improved?
4. Which factors (promotions, season, discounts, weather) really change sales?

## Dataset

| Item | Detail |
|---|---|
| File | `inventory_forecasting.csv` |
| Size | 109,500 daily records |
| Coverage | 5 stores × 30 products × 730 days (2022-01-01 to 2023-12-31) |
| Categories | Clothing, Electronics, Furniture, Toys, Groceries |
| Fields | stock level, units sold, units ordered, demand forecast, price, discount, weather, promotion flag, competitor price, season |

## Tools

PostgreSQL · SQL (CTEs, window functions, views, aggregate filters, indexes)

---

## Database Design

```
stores(store_id)
products(product_id, category)
inventory_records(record_date, store_id, product_id, region, inventory_level, units_sold,
                  units_ordered, demand_forecast, price, discount_pct, weather_condition,
                  holiday_promotion, competitor_price, season)
```

- Data is loaded into a **staging table** first, then moved into the final tables.
- `category` belongs to `products`, because each product has exactly one category.
- **`region` and `price` stay on each record.** In this data every store appears in all 4 regions and every product has many different prices, so they are not store or product attributes.
- `CHECK` rules block negative values, and the primary key `(record_date, store_id, product_id)` blocks duplicates.
- Two indexes support per-item and per-product queries.

## Key Logic: Replenishment

Two views drive the reorder decisions:

- **`v_demand_stats`**: latest stock, average daily sales (last 28 days) and sales variability (last 90 days) for every store-product.
- **`v_replenishment`**: calculates days of cover, a reorder point and a status.

```
reorder point = (avg daily demand × lead time) + (z × variation × √lead time)
```

| Status | Meaning |
|---|---|
| CRITICAL | Stock is below demand during the lead time, so it will run out before a new order arrives |
| REORDER | Stock is below the reorder point |
| OK | No action needed |

Assumptions (lead time = 1 day, review period = 1 day, 95% service level) live in the `replenishment_params` table and can be changed in one place.

---

## How to Run

1. Install PostgreSQL and create an empty database, for example `inventory_db`.
2. Put `inventory_forecasting.csv` somewhere PostgreSQL can read it, such as `C:/Users/Public/`.
3. Open `inventory_analytics.sql` and edit the file path in the `COPY` command (section 2).
4. Run sections 1 to 8 **once**, in order. They create the tables, load the data, and build the views.
5. Run the analysis queries (sections 9 to 25) one at a time.

If the `COPY` command fails with a permission error, move the CSV to a folder every user can read. In pgAdmin or DBeaver, connect as the `postgres` user.

---

## Key Findings

### 1. Replenishment
At a 1-day lead time, of the 150 store-products:

| Status | Items |
|---|---:|
| CRITICAL | 28 |
| REORDER | 62 |
| OK | 60 |

The suggested orders total **16,333 units**. If delivery takes 2 days instead, critical items rise from 28 to **130**, so lead time is the most important assumption to confirm.

By category, critical items are concentrated in **Clothing (13)** and **Furniture (7)**, followed by Electronics (5), Toys (2) and Groceries (1).

### 2. Stock turnover
Every store holds about **1.5 days** of stock and turns it about **242 times a year**. Turnover is almost identical across stores, so it does not separate good stores from bad ones in this data.

### 3. Forecast quality
- The supplied forecast runs **about 11 units too high** and is off by about **14.2%** overall.
- A single correction factor (about 0.895) learned on **2022** and tested on **2023** cuts the error from **14.1% to about 11.1%**.

### 4. What drives sales

| Factor | Effect |
|---|---|
| Holiday promotion | 113.1 vs 93.8 units, about **+20%** |
| Winter | 105.2 units vs about 92 in other seasons |
| Promotion in winter | 123.1 vs 89.2 (autumn, no promotion), about **+38%** |  
| Discount (0–20%) | **No measurable effect in this dataset.**: about 96.5–96.9 units at every level |

### 5. Cost of discounts
Discounts gave away about **43.9 million (7.5% of sales before discount)** without raising sales volume. This suggests testing whether blanket discounting pays for itself.

### 6. Sales and demand pattern
- **Clothing** is the largest category (about 215 million net revenue), then Electronics (131), Furniture (104), Toys (52) and Groceries (37).
- Monthly sales **peak from November to January**, and are lowest in spring and autumn.

---

## Data Checks and Limitations

- **Lead time is an assumption.** The data has no supplier delivery time. Replace it with real supplier data before acting on the order quantities.
- **Zero stock never occurs** in the data, so a classic "stockout rate" would always be 0%. The project uses proxies instead: stock below the day's forecast (about 14.5–15.1% of records per store) and sales above recorded stock (about 5%).
- **The data looks synthetic.** Stock levels do not follow their own inflow and outflow, discounts and competitor prices have no effect on sales, and turnover of about 240 a year is far above real retail norms. Conclusions describe this dataset, not retail in general.
- The forecast correction factor in query 17 is typed in by hand (0.895). Update it if the factor query changes.
- Index speed-ups have not been measured. Use `EXPLAIN ANALYZE` before and after creating the indexes if you want to report timings.

---


## Screenshots

### 1. Inventory Status Counts
<p align="center">
  <img src="https://github.com/user-attachments/assets/58338993-ee0b-45ba-9025-7ecfbe74d939" width="600" alt="Inventory Status Counts">
</p>

### 2. Most Urgent Inventory Items
<p align="center">
  <img src="https://github.com/user-attachments/assets/f7820c62-1124-428e-9570-77a7972e5d1f" width="850" alt="Most Urgent Inventory Items">
</p>

### 3. Two-Day Lead-Time Test
<p align="center">
  <img src="https://github.com/user-attachments/assets/1c53a0e2-dde3-4eef-8e8e-fb6547160aa7" width="600" alt="Two-Day Lead-Time Test">
</p>

### 4. Stock Turnover Analysis
<p align="center">
  <img src="https://github.com/user-attachments/assets/80eb0971-8868-4210-9da9-8084e54e7db5" width="700" alt="Stock Turnover Analysis">
</p>

### 5. Forecast Performance: Before vs. After
<p align="center">
  <img src="https://github.com/user-attachments/assets/c969d86f-eef2-4323-84d5-56ddaf9557a9" width="650" alt="Forecast Performance Before and After">
</p>

### 6. Promotion Effects
<p align="center">
  <img src="https://github.com/user-attachments/assets/536fd4e9-58b6-424e-8cb6-da406344748f" width="650" alt="Promotion Effects">
</p>

### 7. Seasonal Effects
<p align="center">
  <img src="https://github.com/user-attachments/assets/caed6ebd-0886-493e-af8a-8bcbe419f37e" width="650" >
</p>

### 8. Discount Effects
<p align="center">
  <img src="https://github.com/user-attachments/assets/24aed7d2-1a54-4521-a71c-488d472f8a93" width="650" >
</p>

### 9. Sales by Category
<p align="center">
   <img width="478" height="220" alt="Screenshot 2026-11-22 224242" src="https://github.com/user-attachments/assets/6c8d8b8a-d9d6-430a-a63a-ea82ec959abb" />
</p>

### 10. Critical Items by Category
<p align="center">
  <img width="377" height="220" alt="Screenshot 2026-11-22 224952" src="https://github.com/user-attachments/assets/185ecd6d-fc92-4d91-b93d-9dbba3dbe80f" />
</p>

### 11. Stock Shortage by Store
<p align="center">
  <img width="391" height="211" alt="Screenshot 2026-11-22 224431" src="https://github.com/user-attachments/assets/01489667-96dd-4d6a-a230-9e052bb5ed10" />

</p>

### 12. Promotion Effect by Season
<p align="center">
  <img width="512" height="311" alt="Screenshot 2026-11-22 224802" src="https://github.com/user-attachments/assets/e34aa4b5-273b-4cf8-a294-bd1344bcdc19" />
</p>

### 13. Ordered vs Sold
<p align="center">
  <img width="512" height="215" alt="Screenshot 2026-11-22 224838" src="https://github.com/user-attachments/assets/a1b515e4-73d1-4602-8bf0-69ca2b871ebd" />
</p>

---

## Repository Contents

```
├── README.md
├── inventory_analytics.sql                # full script: tables, load, views, analysis
├── inventory_forecasting.csv              # source data
└── screenshots/                           # query results
```

## Possible Next Steps

- Replace the assumed lead time with real supplier data.
- Increase reorder levels ahead of winter and promotions.
- Add a dashboard (Power BI or Excel) on top of `v_replenishment`.
- Schedule a daily refresh of the replenishment results.
