# Team 1 – HW5: Tối ưu hoá truy vấn (Query Optimization)

Mã nguồn minh hoạ các kỹ thuật tối ưu hoá truy vấn theo sách **Fundamentals of Database Systems** (Elmasri & Navathe), chủ yếu Chương 19, cùng phần xử lý truy vấn phân tán (mục 23.5).

Mỗi kỹ thuật thường có hai phần:

- **Notebook Python**: tự cài đặt thuật toán trên dữ liệu nhỏ để thấy rõ từng bước và đếm chi phí.
- **File SQL**: chạy trên PostgreSQL bằng `EXPLAIN ANALYZE` để kiểm chứng rằng một hệ quản trị CSDL thật áp dụng đúng nguyên lý đó.

## Nội dung

| Mục | Kỹ thuật | Notebook (Python) | Demo PostgreSQL |
|---|---|---|---|
| 1 | Tối ưu theo quy tắc kinh nghiệm (Heuristic), §19.1 | `1_Tối_ưu_hóa_theo_Quy_tắc_Kinh_nghiệm_(Heuristic_Based_Query_Optimization).ipynb` | |
| 2 | Tối ưu dựa trên chi phí (Cost-Based Optimization), §19.3 – 19.6 | `2.1_cost_based_optimization.ipynb` | `2.2_cbo_postgres_demo.sql` |
| 5 | Tối ưu cấp độ vật lý và xử lý luồng (iterator, pipelining) | `5.2_iterator_demo.ipynb` | `5.1_physical_demos.sql` |
| 6 | Tối ưu trên lược đồ hình sao (Star Schema), §19.8 | `6.1_star_schema_optimization.ipynb` | `6.2_star_schema_postgres_demo.sql` |
| 7 | Tối ưu ngữ nghĩa (Semantic Query Optimization), §19.10 | `7_Tối_ưu_hóa_Ngữ_nghĩa_(Semantic_Query_Optimization).ipynb` | |
| 8 | Tối ưu truy vấn phân tán: Semijoin, loại bỏ phân mảnh, §23.5 | `8.1_distributed_semijoin.ipynb` | `8.2_distributed_fdw_demo.sql` |

### Tóm tắt từng mục

- **1. Heuristic**: so sánh "tích Descartes rồi mới lọc" với "đẩy phép chọn xuống trước, nối sau" trên truy vấn nhân viên dự án *Aquarius*. Cách heuristic rẻ hơn khoảng 13 lần.
- **2. CBO**: catalog thống kê, ước lượng độ chọn lọc, hàm chi phí cho phép chọn (S1 – S6) và phép nối (J1 – J4), chọn thứ tự nối bằng quy hoạch động (kiểm chứng bằng cách vét cạn 24 thứ tự). Phần SQL tự tính lại chi phí của PostgreSQL từ `pg_class`/`pg_stats`, cho thấy thống kê cũ dẫn tới kế hoạch sai và giới hạn ước lượng của CBO khi dữ liệu lệch.
- **5. Cấp độ vật lý**: đường truy xuất và độ chọn lọc, các giải thuật nối (nested-loop, index nested-loop, sort-merge, hash, partition-hash), cây nối lệch trái, xử lý luồng và vật lý hoá kết quả trung gian. Notebook cài đặt mô hình iterator `open / get_next / close`.
- **6. Star Schema**: so sánh hash join thông thường, chỉ mục một chiều, **biến đổi hình sao** (bitmap index, OR / AND bitmap, nối ngược), **loại bỏ nối ngược** và **nối hình sao** (tích Descartes các chiều + chỉ mục ghép); chỉ ra khi nào các kỹ thuật này không có lợi. Phần SQL dựng kho dữ liệu `dw` khoảng 1,2 triệu dòng sự kiện.
- **7. Semantic**: dùng ràng buộc trên lược đồ để biết trước kết quả rỗng, và bỏ phép nối thừa nhờ khoá ngoại (cần thêm `IS NOT NULL`).
- **8. Phân tán**: mô phỏng nhiều trạm và đếm số byte truyền qua mạng cho các chiến lược truyền thẳng / semijoin; loại bỏ phân mảnh dựa trên điều kiện bảo vệ. Phần SQL dùng `postgres_fdw` để giả lập hai trạm.

## Cơ sở dữ liệu

Thư mục `database/` chứa CSDL **COMPANY** của sách, chuyển sang PostgreSQL:

| File | Nội dung |
|---|---|
| `01_employee_database_pg.sql` | Lược đồ 6 bảng (`employee`, `department`, `dept_locations`, `project`, `works_on`, `dependent`) và dữ liệu mẫu của sách |
| `02_generate_large_data_pgadmin.sql` | Sinh thêm dữ liệu lớn: 100.000 nhân viên, khoảng 200.000 dòng `works_on`, 500 dự án, 20 phòng ban. Dữ liệu cố ý **lệch** (40% nhân viên ở phòng 5) và cố định seed để ai chạy cũng ra cùng kết quả |

Sau khi chạy hai file: `employee` 100.008 dòng, `works_on` 200.061 dòng, `project` 506 dòng, `department` 20 dòng.

## Cách chạy

### Yêu cầu

- Python 3 và Jupyter (các notebook chỉ dùng thư viện chuẩn, không cần cài thêm gói).
- PostgreSQL (đã thử trên bản 16) và pgAdmin hoặc DBeaver.
- Khoảng 300 MB đĩa trống cho CSDL, chủ yếu do kho dữ liệu `dw` của mục 6.

### Notebook

Mở notebook trong Jupyter hoặc VS Code rồi chọn *Run All*. Các notebook độc lập với nhau và không cần kết nối CSDL.

### Demo PostgreSQL

1. Tạo CSDL `company` rồi chạy hai file dữ liệu theo thứ tự:
   ```bash
   createdb company
   psql -d company -f database/01_employee_database_pg.sql
   psql -d company -f database/02_generate_large_data_pgadmin.sql
   ```
   Hoặc trong pgAdmin: mở Query Tool trên CSDL `company`, mở từng file rồi bấm Execute (F5).
2. Mở file demo (`2.2`, `5.1`, `6.2`, `8.2`) trong Query Tool. **Bôi đen từng khối rồi bấm F5**, chạy đúng thứ tự từ trên xuống. Không chạy cả file một lần, vì pgAdmin chỉ hiện kết quả của câu cuối và các khối sau cần chỉ mục do khối trước tạo.
3. Sau mỗi khối có lệnh `SET ...`, chạy `RESET ALL;` trước khi sang khối khác.
4. So sánh kết quả với các dòng `-- Kỳ vọng:` trong file. Số dòng ước lượng có thể lệch một chút giữa các lần `ANALYZE` (vì `ANALYZE` lấy mẫu), còn thời gian chạy phụ thuộc vào máy.

Lưu ý riêng:

- **`6.2_star_schema_postgres_demo.sql`**: chạy *Phần 0* một lần để dựng schema `dw` (mất vài giây). Dọn dẹp bằng `DROP SCHEMA dw CASCADE;`.
- **`8.2_distributed_fdw_demo.sql`**: cần extension `postgres_fdw` và tạo thêm CSDL `site2`. Mỗi khối ghi rõ phải chạy trên CSDL nào; nhớ sửa mật khẩu trong lệnh `CREATE USER MAPPING`.

## Viết báo cáo

Các notebook và file SQL có sẵn chỗ để điền:

- `(Dán ảnh kết quả EXPLAIN vào đây ...)` trong notebook: dán ảnh chụp kết quả `EXPLAIN ANALYZE` tương ứng.
- Các bảng `(điền)` ở cuối mỗi file SQL: ghi `cost` ước lượng và `Execution Time` thực tế để so sánh các kế hoạch.
