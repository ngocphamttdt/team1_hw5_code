-- =====================================================================
-- MỤC 2. TỐI ƯU HOÁ DỰA TRÊN CHI PHÍ (COST-BASED OPTIMIZATION) - DEMO TRÊN POSTGRESQL
-- Sách Chương 19, mục 19.3 - 19.6. Đi kèm notebook 2.1_cost_based_optimization.ipynb
-- CSDL company, đã chạy file 01 và 02.
--
-- CÁCH CHẠY TRONG pgADMIN:
--   Bôi đen TỪNG KHỐI (hoặc từng câu EXPLAIN) rồi bấm F5.
--   Không chạy cả file một lần, vì pgAdmin chỉ hiện kết quả câu cuối.
--   Sau mỗi khối có SET ..., luôn chạy RESET ALL; trước khi sang khối khác.
--
-- Các con số "Kỳ vọng" bên dưới lấy từ một lần chạy thử. Số dòng ước lượng
-- có thể lệch một chút giữa các lần ANALYZE (ANALYZE lấy MẪU ngẫu nhiên),
-- thời gian chạy phụ thuộc máy.
-- =====================================================================


-- #####################################################################
-- DEMO 1. CATALOG: THỐNG KÊ MÀ BỘ TỐI ƯU DÙNG (mục 19.3)
-- Tương ứng phần 1 của notebook: r, b, NDV
-- #####################################################################

-- 1a. r = reltuples (số dòng), b = relpages (số khối 8 KB)
SELECT relname                          AS bang,
       reltuples::bigint                AS r_so_dong,
       relpages                         AS b_so_khoi,
       round(reltuples / relpages)      AS bfr_dong_moi_khoi
FROM pg_class
WHERE relname IN ('employee', 'works_on', 'project', 'department')
ORDER BY reltuples DESC;
-- Kỳ vọng: employee 100008 dòng / 1332 khối; works_on 200061 / 1275.

-- 1b. NDV và phân bố giá trị của từng cột
--     n_distinct > 0 : số giá trị khác nhau (NDV)
--     n_distinct < 0 : -(NDV / r), dùng khi NDV tăng theo số dòng (ví dụ cột khoá)
SELECT attname, n_distinct, null_frac
FROM pg_stats
WHERE tablename = 'employee'
  AND attname IN ('ssn', 'dno', 'sex', 'salary', 'lname');
-- Kỳ vọng: ssn = -1 (mọi giá trị khác nhau, NDV = r), dno = 20, sex = 2.

-- 1c. Giá trị phổ biến nhất (MCV) và tần suất: PostgreSQL KHÔNG giả định
--     phân bố đều như công thức 1/NDV của sách mà lưu tần suất thật.
SELECT most_common_vals  AS gia_tri_dno,
       most_common_freqs AS tan_suat
FROM pg_stats
WHERE tablename = 'employee' AND attname = 'dno';
-- Kỳ vọng: dno 5 khoảng 0.42, dno 4 khoảng 0.22, các phòng khác khoảng 0.02
--          (đúng với dữ liệu cố ý làm lệch ở file 02).


-- #####################################################################
-- DEMO 2. HÀM CHI PHÍ: TỰ TÍNH CHI PHÍ SEQ SCAN (mục 19.4, phương pháp S1)
-- Công thức của PostgreSQL cho quét tuần tự:
--   cost = b × seq_page_cost + r × cpu_tuple_cost  (+ r × cpu_operator_cost nếu có WHERE)
-- Khác sách ở chỗ có cộng thêm chi phí CPU, nhưng thành phần chính vẫn là số khối b.
-- #####################################################################

SHOW seq_page_cost;      -- 1
SHOW random_page_cost;   -- 4: đọc ngẫu nhiên (qua chỉ mục) đắt gấp 4 lần đọc tuần tự
SHOW cpu_tuple_cost;     -- 0.01
SHOW cpu_operator_cost;  -- 0.0025

SELECT relpages * current_setting('seq_page_cost')::float8
     + reltuples * current_setting('cpu_tuple_cost')::float8           AS cost_khong_where,
       relpages * current_setting('seq_page_cost')::float8
     + reltuples * (current_setting('cpu_tuple_cost')::float8
                  + current_setting('cpu_operator_cost')::float8)      AS cost_co_where
FROM pg_class WHERE relname = 'employee';
-- Kỳ vọng: 2332.08 và 2582.10

EXPLAIN SELECT * FROM employee;
EXPLAIN SELECT * FROM employee WHERE dno = 5;
-- Cần chỉ ra: cost=0.00..2332.08 và cost=0.00..2582.10, KHỚP ĐÚNG số tự tính.
-- Con số thứ hai trong cost=A..B là tổng chi phí; A là chi phí trước khi trả dòng đầu tiên.


-- #####################################################################
-- DEMO 3. ƯỚC LƯỢNG ĐỘ CHỌN LỌC (mục 19.3)
-- s = sl × r. PostgreSQL lấy sl của "dno = v" từ most_common_freqs.
-- #####################################################################

-- 3a. Tự tính số dòng ước lượng từ thống kê
SELECT v.dno,
       round(c.reltuples * s.most_common_freqs[array_position(s.most_common_vals::text::int[], v.dno)])
           AS rows_tu_tinh,
       round(c.reltuples / 20)                 AS rows_neu_gia_dinh_deu_1_tren_NDV
FROM pg_stats s, pg_class c, (VALUES (5), (17)) AS v(dno)
WHERE s.tablename = 'employee' AND s.attname = 'dno' AND c.relname = 'employee';

-- 3b. So với số dòng ước lượng (rows=) trong EXPLAIN và số dòng thật (actual rows)
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno = 5;
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno = 17;
-- Kỳ vọng: rows ước lượng khoảng 42000 và khoảng 2000, khớp 3a và gần số thật.
-- Nếu chỉ dùng công thức 1/NDV của sách, cả hai đều ra 5000: sai gấp 8 lần với dno = 5.

-- 3c. Điều kiện hội (AND): nhân độ chọn lọc, giả định các cột độc lập
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno = 17 AND sex = 'F';
-- Kỳ vọng: rows ước lượng khoảng 2000 × 0.5 = 1000.


-- #####################################################################
-- DEMO 4. CÓ CHỈ MỤC CHƯA CHẮC ĐÃ DÙNG (OP2 / OP3 trong notebook)
-- Cùng một câu, chỉ đổi điều kiện -> bộ tối ưu chọn đường truy xuất khác.
-- #####################################################################

CREATE INDEX IF NOT EXISTS idx_emp_dno ON employee (dno);
ANALYZE employee;

-- 4a. Điều kiện lấy lên khoảng 64% bảng (giống OP2): quét tuần tự
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno IN (4, 5);
-- Kỳ vọng: Seq Scan, cost khoảng 2582

-- 4b. Ép dùng chỉ mục để thấy vì sao bộ tối ưu không chọn
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno IN (4, 5);
RESET ALL;
-- Kỳ vọng: Bitmap Heap Scan, cost khoảng 2790 > 2582 -> đắt hơn quét tuần tự.

-- 4c. Điều kiện chọn lọc (khoảng 2%, giống OP3): dùng chỉ mục
EXPLAIN ANALYZE SELECT * FROM employee WHERE dno = 17;
-- Kỳ vọng: Bitmap Index Scan on idx_emp_dno, cost khoảng 1445 < 2582.

-- 4d. Bằng trên khoá (giống OP1): chỉ mục khoá chính, chỉ vài khối
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employee WHERE ssn = '123456789';
-- Kỳ vọng: Index Scan using employee_pkey, Buffers: shared hit khoảng 3-4 khối.


-- #####################################################################
-- DEMO 5. THỐNG KÊ CŨ -> ƯỚC LƯỢNG SAI -> KẾ HOẠCH SAI
-- Bảng emp_stale: ANALYZE khi chỉ có nhân viên phòng 1, sau đó mới chèn
-- toàn bộ nhân viên còn lại. Tắt autovacuum để thống kê không tự cập nhật.
-- #####################################################################

DROP TABLE IF EXISTS emp_stale;
CREATE TABLE emp_stale (LIKE employee) WITH (autovacuum_enabled = false);
INSERT INTO emp_stale SELECT * FROM employee WHERE dno = 1;
ANALYZE emp_stale;                                       -- thống kê: chỉ có phòng 1
INSERT INTO emp_stale SELECT * FROM employee WHERE dno <> 1;

-- 5a. Thống kê cũ
EXPLAIN ANALYZE
SELECT e.lname, w.pno
FROM emp_stale e JOIN works_on w ON w.essn = e.ssn
WHERE e.dno = 5;
-- Kỳ vọng: Seq Scan on emp_stale: rows=1 (ước lượng) nhưng actual rows=42029.
--          Bộ tối ưu tưởng chỉ có 1 nhân viên nên chọn Nested Loop,
--          tra chỉ mục works_on 42029 lần (loops=42029).

-- 5b. Cập nhật thống kê rồi chạy lại
ANALYZE emp_stale;
EXPLAIN ANALYZE
SELECT e.lname, w.pno
FROM emp_stale e JOIN works_on w ON w.essn = e.ssn
WHERE e.dno = 5;
-- Kỳ vọng: rows ước lượng khoảng 42000, gần số thật; kế hoạch đổi sang Hash Join.
-- So sánh hai lần: cùng câu SQL, cùng dữ liệu, chỉ khác thống kê -> khác kế hoạch.

DROP TABLE emp_stale;


-- #####################################################################
-- DEMO 6. THỨ TỰ NỐI (mục 19.5 - 19.6, phần 5 của notebook)
-- Câu truy vấn 4 bảng giống notebook. Chạy SAU Demo 4 (cần idx_emp_dno).
-- #####################################################################

-- 6a. Bộ tối ưu tự chọn thứ tự nối
EXPLAIN ANALYZE
SELECT e.lname, p.pname
FROM employee e
JOIN works_on   w ON e.ssn = w.essn
JOIN project    p ON w.pno = p.pnumber
JOIN department d ON e.dno = d.dnumber
WHERE d.dname = 'Research' AND p.plocation = 'Stafford';
-- Kỳ vọng (đọc cây từ trong ra ngoài):
--   department (1 dòng) -> Nested Loop + Bitmap Index Scan employee (idx_emp_dno)
--   -> Nested Loop + Index Only Scan works_on_pkey -> Hash Join với project đã lọc.
--   Đúng thứ tự (((D ⋈ E) ⋈ W) ⋈ P) mà quy hoạch động trong notebook đã chọn.
--   Ghi lại: cost tổng (khoảng 4072) và Execution Time.

-- 6b. Ép thứ tự tệ: tích Descartes EMPLOYEE × PROJECT trước
--     join_collapse_limit = 1 buộc PostgreSQL nối đúng thứ tự viết trong FROM.
SET join_collapse_limit = 1;
EXPLAIN ANALYZE
SELECT e.lname, p.pname
FROM employee e
CROSS JOIN project p
JOIN works_on   w ON e.ssn = w.essn AND w.pno = p.pnumber
JOIN department d ON e.dno = d.dnumber
WHERE d.dname = 'Research' AND p.plocation = 'Stafford';
RESET ALL;
-- Kỳ vọng: cost khoảng 228000 (gấp hơn 50 lần 6a); Nested Loop sinh ra khoảng
--          7,8 triệu dòng trung gian; Execution Time vài giây so với vài chục ms.

-- 6c. Ép thứ tự khác: WORKS_ON ⋈ EMPLOYEE trước (không có tích Descartes)
SET join_collapse_limit = 1;
EXPLAIN ANALYZE
SELECT e.lname, p.pname
FROM works_on w
JOIN employee   e ON e.ssn = w.essn
JOIN department d ON e.dno = d.dnumber
JOIN project    p ON w.pno = p.pnumber
WHERE d.dname = 'Research' AND p.plocation = 'Stafford';
RESET ALL;
-- Kỳ vọng: cost khoảng 6973, lớn hơn 6a (4072), nhưng Execution Time chỉ cùng cỡ
--          với 6a (chạy vài lần: có lần nhanh hơn, có lần chậm hơn), chứ không
--          chậm hơn 70% như tỉ lệ cost. Ước lượng của 6a chưa chính xác, xem 6d.

-- 6d. Giới hạn của CBO: ước lượng sai khi điều kiện nằm ở bảng khác
--     Ở 6a, nút Bitmap Heap Scan on employee: rows=5000 (ước lượng)
--     nhưng actual rows=42029. PostgreSQL biết phòng 'Research' chỉ là 1 dòng
--     trong department, nhưng KHÔNG biết đó là phòng 5 chiếm 42% nhân viên,
--     nên ước lượng 100008 / 20 phòng = 5000. Với phòng nhỏ thì khác:
EXPLAIN ANALYZE
SELECT e.lname, p.pname
FROM employee e
JOIN works_on   w ON e.ssn = w.essn
JOIN project    p ON w.pno = p.pnumber
JOIN department d ON e.dno = d.dnumber
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford';
-- Kỳ vọng: cùng kế hoạch, cùng cost 4072 như 6a (vì ước lượng giống hệt: 5000),
--          nhưng actual rows của employee chỉ khoảng 2000 và Execution Time
--          nhỏ hơn 6a hơn 10 lần. Với 'Dept_17' kế hoạch này đúng là tốt nhất;
--          với 'Research' (dữ liệu lệch) nó chưa chắc tốt nhất.
--
-- So sánh để đưa vào báo cáo:
--   | Câu | Thứ tự nối               | cost ước lượng | Execution Time |
--   | 6a  | bộ tối ưu chọn            | (điền)         | (điền)         |
--   | 6b  | E × P trước (Descartes)   | (điền)         | (điền)         |
--   | 6c  | W ⋈ E trước               | (điền)         | (điền)         |
--   | 6d  | như 6a, phòng nhỏ         | (điền)         | (điền)         |


-- #####################################################################
-- DỌN DẸP (tuỳ chọn)
-- #####################################################################
RESET ALL;
-- DROP INDEX IF EXISTS idx_emp_dno;
