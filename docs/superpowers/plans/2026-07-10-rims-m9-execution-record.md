# RIMS M9 Execution Record

Status: IN PROGRESS

This record is populated only from observed local output. Final environment,
smoke, baseline, defect, and pass/fail evidence will be appended during the M9
acceptance run.

## Pagination Endpoint Audit

| Frontend operation | Backend contract | Classification | Consumer behavior |
| --- | --- | --- | --- |
| Current-user warehouses | `GET /users/me/warehouses` returns a complete array | Unpaged reference data | Session warehouse selector consumes the complete list |
| Inventory | `GET /inventory` returns `PageResult` | Paged | `PageData<InventoryItem>` with reset, append, retry, and total |
| Inventory alerts | `GET /inventory/alerts` returns `PageResult` | Paged preview | Home uses server `total`; inventory UI does not infer totals from page items |
| Non-standard inventory | `GET /non-std-inventory` returns `PageResult` | Paged | Home uses server `total`; conversion selector traverses all pages |
| Documents | `GET /documents` returns `PageResult` | Paged | Documents UI paginates; home renders a bounded preview with server total |
| Inventory transactions | `GET /transactions` returns `PageResult` | Paged | Documents UI paginates; inventory detail traverses all pages before product filtering |
| Admin users | `GET /users` returns `PageResult` | Paged | Admin panel uses `PageData<AdminUser>` |
| Admin products | `GET /products` returns `PageResult` | Paged | Admin panel uses `PageData<AdminProduct>` |
| Admin warehouses | `GET /warehouses` returns `PageResult` | Paged | Admin panel uses `PageData<AdminWarehouse>` |
| Warehouse-bound users | `GET /warehouses/{id}/users` returns `PageResult` | Paged | Binding editor traverses all pages and deduplicates by user ID |
| Roles | `GET /roles` returns a complete array | Unpaged reference data | Role editor consumes the complete list |
| Permissions | `GET /permissions` returns a complete array | Unpaged reference data | Permission editor consumes the complete list |
| Sales trend | `GET /reports/sales/trend` returns an aggregate response | Unpaged aggregate | Chart consumes all server-produced buckets |
| Sales ranking | `GET /reports/sales/ranking` accepts `limit` | Server-bounded ranking | UI requests and renders the server top 5 |
| Inventory overview | `GET /reports/inventory/overview` returns a summary object | Unpaged aggregate | Dashboard consumes summary buckets |
| Inventory turnover | `GET /reports/inventory/turnover` accepts `limit` | Server-bounded ranking | UI requests and renders the server top 5 |
| Slow-moving inventory | `GET /reports/inventory/slow-moving` returns `PageResult` | Paged preview | Repository preserves `PageData`; report exposes preview items and server total |

## Pending Acceptance Evidence

- Frontend and backend branch/commit identities
- Environment and tool versions
- Fixture counts
- Timestamped command results and report paths
- Web and Android scenario results
- Baseline summary
- P0/P1/P2/P3 defect table
- Plan deviations and rationale
- Explicit M9 pass/fail decision
