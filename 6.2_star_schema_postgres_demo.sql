-- =====================================================================
-- MỤC 6. TỐI ƯU HOÁ TRUY VẤN TRÊN LƯỢC ĐỒ HÌNH SAO (STAR SCHEMA) - DEMO TRÊN POSTGRESQL
-- Sách Chương 19, mục 19.8. Đi kèm notebook 6.1_star_schema_optimization.ipynb
-- CSDL company, đã chạy file 01 và 02.
--
-- Dựng một kho dữ liệu nhỏ trong schema dw từ dữ liệu COMPANY:
--   dw.fact_work      : số giờ mỗi nhân viên làm cho mỗi dự án mỗi tháng (khoảng 1,2 triệu dòng)
--   dw.dim_employee   : 100.008 dòng      dw.dim_project : 506 dòng
--   dw.dim_department : 20 dòng           dw.dim_time    : 24 tháng (2023 - 2024)
--
-- CÁCH CHẠY TRONG pgADMIN:
--   Chạy PHẦN 0 một lần (bôi đen cả phần, F5, mất vài giây).
--   Sau đó bôi đen TỪNG KHỐI demo rồi bấm F5, ĐÚNG THỨ TỰ (các demo sau cần
--   chỉ mục tạo ở demo trước). Chạy mỗi câu EXPLAIN 2-3 lần, lấy kết quả ổn định.
--
-- PostgreSQL KHÔNG có bitmap index lưu trên đĩa và KHÔNG tự biến đổi hình sao
-- như Oracle. Nó dựng bitmap trong RAM từ chỉ mục B-tree lúc chạy
-- (Bitmap Index Scan) và AND được nhiều bitmap (BitmapAnd). Demo 3 tự viết
-- lại câu truy vấn để mô phỏng biến đổi hình sao.
-- =====================================================================


-- #####################################################################
-- PHẦN 0. DỰNG LƯỢC ĐỒ HÌNH SAO (chạy một lần)
-- #####################################################################
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

CREATE TABLE dw.dim_department AS
SELECT dnumber AS dept_key, dname FROM department;
ALTER TABLE dw.dim_department ADD PRIMARY KEY (dept_key);

CREATE TABLE dw.dim_project AS
SELECT pnumber AS proj_key, pname, plocation FROM project;
ALTER TABLE dw.dim_project ADD PRIMARY KEY (proj_key);

CREATE TABLE dw.dim_employee AS
SELECT row_number() OVER (ORDER BY ssn)::int        AS emp_key,
       ssn, fname, lname, sex,
       (extract(year FROM bdate)::int / 10) * 10    AS birth_decade
FROM employee;
ALTER TABLE dw.dim_employee ADD PRIMARY KEY (emp_key);

CREATE TABLE dw.dim_time AS
SELECT (extract(year FROM m) * 100 + extract(month FROM m))::int AS time_key,
       extract(month FROM m)::int   AS month,
       extract(quarter FROM m)::int AS quarter,
       extract(year FROM m)::int    AS year
FROM generate_series(DATE '2023-01-01', DATE '2024-12-01', INTERVAL '1 month') AS m;
ALTER TABLE dw.dim_time ADD PRIMARY KEY (time_key);

-- Mỗi dòng works_on xuất hiện ở khoảng 1/4 số tháng, số giờ từ 1.0 đến 40.0.
-- Dùng hàm băm hashtext() thay cho random(): ai chạy cũng ra cùng một bộ dữ liệu.
CREATE TABLE dw.fact_work AS
SELECT de.emp_key,
       w.pno     AS proj_key,
       e.dno     AS dept_key,
       t.time_key,
       round(1 + (abs(hashtext(w.essn || '/' || w.pno || '/' || t.time_key || '/h')) % 391) / 10.0, 1) AS hours
FROM works_on w
JOIN employee e         ON e.ssn = w.essn
JOIN dw.dim_employee de ON de.ssn = e.ssn
CROSS JOIN dw.dim_time t
WHERE abs(hashtext(w.essn || '/' || w.pno || '/' || t.time_key)) % 4 = 0;

ANALYZE;

-- Kiểm tra: fact_work khoảng 1.200.000 dòng, khoảng 60 MB
SELECT (SELECT count(*) FROM dw.fact_work)                     AS fact_work,
       pg_size_pretty(pg_relation_size('dw.fact_work'))        AS kich_thuoc,
       (SELECT count(*) FROM dw.dim_employee)                  AS dim_employee,
       (SELECT count(*) FROM dw.dim_project)                   AS dim_project,
       (SELECT count(*) FROM dw.dim_department)                AS dim_department,
       (SELECT count(*) FROM dw.dim_time)                      AS dim_time;


-- #####################################################################
-- CÂU TRUY VẤN DÙNG CHUNG
-- Tổng số giờ theo dự án, của phòng Dept_17, dự án đặt tại Stafford, quý 1/2024.
-- Độ chọn lọc trên bảng sự kiện: từng điều kiện riêng lẻ yếu, kết hợp rất mạnh.
-- #####################################################################
SELECT 'dname = Dept_17'          AS dieu_kien, count(*) AS so_dong_su_kien
FROM dw.fact_work f JOIN dw.dim_department d ON f.dept_key = d.dept_key WHERE d.dname = 'Dept_17'
UNION ALL
SELECT 'plocation = Stafford', count(*)
FROM dw.fact_work f JOIN dw.dim_project p ON f.proj_key = p.proj_key WHERE p.plocation = 'Stafford'
UNION ALL
SELECT 'quý 1/2024', count(*)
FROM dw.fact_work f JOIN dw.dim_time t ON f.time_key = t.time_key WHERE t.year = 2024 AND t.quarter = 1
UNION ALL
SELECT 'cả ba điều kiện', count(*)
FROM dw.fact_work f
JOIN dw.dim_department d ON f.dept_key = d.dept_key
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1;
-- Kỳ vọng: 24.852 / 191.735 / 149.577 dòng riêng lẻ, nhưng chỉ 461 dòng khi kết hợp.


-- #####################################################################
-- DEMO 1. KẾ HOẠCH THÔNG THƯỜNG, CHƯA CÓ CHỈ MỤC TRÊN KHOÁ NGOẠI
-- (Thí nghiệm 1 của notebook)
-- #####################################################################
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pname, sum(f.hours)
FROM dw.fact_work f
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
JOIN dw.dim_department d ON f.dept_key = d.dept_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1
GROUP BY p.pname;
-- Kỳ vọng: (Parallel) Seq Scan on fact_work đọc TOÀN BỘ khoảng 1,2 triệu dòng
--          (rows=400000 x loops=3 nếu chạy song song), rồi Hash Join lần lượt
--          với từng bảng chiều đã lọc. Ghi lại Execution Time và Buffers.


-- #####################################################################
-- DEMO 2. CHỈ MỤC B-TREE TRÊN TỪNG KHOÁ NGOẠI CỦA BẢNG SỰ KIỆN
-- (Thí nghiệm 2 của notebook)
-- #####################################################################
CREATE INDEX fact_work_dept_key_idx ON dw.fact_work (dept_key);
CREATE INDEX fact_work_proj_key_idx ON dw.fact_work (proj_key);
CREATE INDEX fact_work_time_key_idx ON dw.fact_work (time_key);
CREATE INDEX fact_work_emp_key_idx  ON dw.fact_work (emp_key);
ANALYZE dw.fact_work;

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pname, sum(f.hours)
FROM dw.fact_work f
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
JOIN dw.dim_department d ON f.dept_key = d.dept_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1
GROUP BY p.pname;
-- Kỳ vọng: Nested Loop: dim_department (1 dòng) -> Bitmap Index Scan on
--          fact_work_dept_key_idx. Bộ tối ưu chỉ dùng chỉ mục của MỘT chiều
--          (chọn lọc nhất): đọc khoảng 24.850 dòng sự kiện của phòng 17, rồi
--          Hash Join với dim_project, dim_time loại gần hết -> còn khoảng 460.


-- #####################################################################
-- DEMO 3. BIẾN ĐỔI HÌNH SAO (STAR TRANSFORMATION)
-- (Thí nghiệm 3 của notebook)
-- #####################################################################

-- 3a. Bước 1: chạy các truy vấn con trên bảng chiều -> tập khoá
SELECT array_agg(dept_key) AS khoa_phong   FROM dw.dim_department WHERE dname = 'Dept_17';
SELECT array_agg(time_key) AS khoa_thang   FROM dw.dim_time       WHERE year = 2024 AND quarter = 1;
SELECT array_agg(proj_key) AS khoa_du_an,
       count(*)            AS so_du_an     FROM dw.dim_project    WHERE plocation = 'Stafford';

-- 3b. Viết lại trực tiếp bằng truy vấn con: PostgreSQL CHƯA làm tốt
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pname, sum(f.hours)
FROM dw.fact_work f
JOIN dw.dim_project p ON f.proj_key = p.proj_key                        -- nối ngược
WHERE f.dept_key = ANY (ARRAY(SELECT dept_key FROM dw.dim_department WHERE dname = 'Dept_17'))
  AND f.proj_key = ANY (ARRAY(SELECT proj_key FROM dw.dim_project    WHERE plocation = 'Stafford'))
  AND f.time_key = ANY (ARRAY(SELECT time_key FROM dw.dim_time       WHERE year = 2024 AND quarter = 1))
GROUP BY p.pname;
-- Kỳ vọng: 3 InitPlan chạy các truy vấn con trước (đúng bước 1), nhưng lúc lập
--          kế hoạch PostgreSQL CHƯA biết các mảng có bao nhiêu phần tử nên
--          ước lượng sai và chỉ dùng chỉ mục proj_key (Heap Blocks khoảng 7.500,
--          chậm hơn cả Demo 2). Đây là lý do
--          Oracle cài biến đổi hình sao ngay trong bộ tối ưu.

-- 3c. Mô phỏng đúng biến đổi hình sao: hàm chạy bước 1, rồi đưa các tập khoá
--     vào câu truy vấn dưới dạng hằng số để bộ tối ưu biết chính xác.
CREATE OR REPLACE FUNCTION dw.star_transform(join_back boolean DEFAULT true)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
    k_dept int[];
    k_time int[];
    k_proj int[];
    sql    text;
BEGIN
    -- Bước 1: truy vấn con trên bảng chiều
    SELECT array_agg(dept_key) INTO k_dept FROM dw.dim_department WHERE dname = 'Dept_17';
    SELECT array_agg(time_key) INTO k_time FROM dw.dim_time       WHERE year = 2024 AND quarter = 1;
    SELECT array_agg(proj_key) INTO k_proj FROM dw.dim_project    WHERE plocation = 'Stafford';
    -- Bước 2 - 4: lọc bảng sự kiện theo tập khoá của MỌI chiều
    IF join_back THEN
        sql := 'SELECT p.pname, sum(f.hours) FROM dw.fact_work f '
            || 'JOIN dw.dim_project p ON f.proj_key = p.proj_key ';     -- bước 5: nối ngược
    ELSE
        sql := 'SELECT sum(f.hours) FROM dw.fact_work f ';
    END IF;
    sql := sql || format('WHERE f.dept_key = ANY (%L) AND f.time_key = ANY (%L) AND f.proj_key = ANY (%L)',
                         k_dept, k_time, k_proj);
    IF join_back THEN
        sql := sql || ' GROUP BY p.pname';
    END IF;
    RETURN QUERY EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || sql;
END $$;

SELECT * FROM dw.star_transform(true);
-- Kỳ vọng:
--   BitmapAnd
--     -> Bitmap Index Scan on fact_work_dept_key_idx   rows khoảng 24.850
--     -> Bitmap Index Scan on fact_work_time_key_idx   rows khoảng 150.000
--     -> Bitmap Index Scan on fact_work_proj_key_idx   rows khoảng 192.000
--   Bitmap Heap Scan on fact_work: actual rows khoảng 460, Heap Blocks khoảng 330
--   -> chỉ đọc ĐÚNG các dòng sự kiện có trong kết quả (Demo 2 đọc 24.850).
--   Mỗi bitmap riêng lẻ khá lớn, nhưng AND xong chỉ còn khoảng 460 dòng.
--   Để ý: "Bitmap Index Scan" = OR các khoá trong một chiều (bước 2),
--         "BitmapAnd" = AND giữa các chiều (bước 3).


-- #####################################################################
-- DEMO 4. LOẠI BỎ NỐI NGƯỢC (JOIN-BACK ELIMINATION)
-- (Thí nghiệm 4 của notebook)
-- Câu hỏi chỉ cần tổng số giờ, không cần cột nào của bảng chiều.
-- #####################################################################
SELECT * FROM dw.star_transform(false);
-- Kỳ vọng: giống 3c nhưng KHÔNG còn Hash Join với dim_project, chỉ còn
--          Aggregate trên Bitmap Heap Scan. Execution Time nhỏ hơn 3c.

-- Kiểm tra kết quả: hai câu dưới phải cho cùng một con số
SELECT sum(f.hours) AS cau_goc
FROM dw.fact_work f
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
JOIN dw.dim_department d ON f.dept_key = d.dept_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1;

SELECT sum(f.hours) AS cau_bien_doi
FROM dw.fact_work f
WHERE f.dept_key IN (SELECT dept_key FROM dw.dim_department WHERE dname = 'Dept_17')
  AND f.proj_key IN (SELECT proj_key FROM dw.dim_project    WHERE plocation = 'Stafford')
  AND f.time_key IN (SELECT time_key FROM dw.dim_time       WHERE year = 2024 AND quarter = 1);


-- #####################################################################
-- DEMO 5. NỐI HÌNH SAO (STAR JOIN): TÍCH DESCARTES CÁC CHIỀU + CHỈ MỤC GHÉP
-- (Thí nghiệm 5 của notebook)
-- #####################################################################
CREATE INDEX fact_dtp ON dw.fact_work (dept_key, time_key, proj_key);
ANALYZE dw.fact_work;

-- 5a. Câu truy vấn gốc, để bộ tối ưu tự chọn
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pname, sum(f.hours)
FROM dw.fact_work f
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
JOIN dw.dim_department d ON f.dept_key = d.dept_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1
GROUP BY p.pname;
-- Kỳ vọng: PostgreSQL TỰ chọn nối hình sao:
--   Nested Loop: dim_department (1) -> dim_time (3) -> dim_project (78)
--   -> Index Scan using fact_dtp on fact_work, loops = 1 x 3 x 78 = 234
--   Ba bảng chiều không có điều kiện nối với nhau: đây là TÍCH DESCARTES,
--   mỗi tổ hợp khoá tra MỘT lần vào chỉ mục ghép.
--   Execution Time nhỏ nhất trong các demo (dưới 1 ms khi dữ liệu đã ở RAM).

-- 5b. Viết tường minh tích Descartes trước, ép đúng thứ tự viết
SET join_collapse_limit = 1;
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pname, sum(f.hours)
FROM dw.dim_department d
CROSS JOIN dw.dim_time t
CROSS JOIN dw.dim_project p
JOIN dw.fact_work f ON f.dept_key = d.dept_key AND f.time_key = t.time_key AND f.proj_key = p.proj_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1
GROUP BY p.pname;
RESET ALL;
-- Kỳ vọng: nút Nested Loop của các bảng chiều trả rows=234 (tích Descartes),
--          rồi Index Scan using fact_dtp, loops=234.

-- 5c. Khi một chiều còn nhiều dòng, tích Descartes bùng nổ
--     Thêm điều kiện sex = 'F' trên dim_employee (khoảng 50.000 nhân viên):
--     tích Descartes = 1 x 3 x 78 x 50.000 = khoảng 11,7 triệu tổ hợp,
--     lớn hơn cả bảng sự kiện. Bộ tối ưu dựa trên chi phí phải nhận ra điều này:
EXPLAIN
SELECT p.pname, sum(f.hours)
FROM dw.fact_work f
JOIN dw.dim_project    p ON f.proj_key = p.proj_key
JOIN dw.dim_time       t ON f.time_key = t.time_key
JOIN dw.dim_department d ON f.dept_key = d.dept_key
JOIN dw.dim_employee   e ON f.emp_key  = e.emp_key
WHERE d.dname = 'Dept_17' AND p.plocation = 'Stafford' AND t.year = 2024 AND t.quarter = 1
  AND e.sex = 'F'
GROUP BY p.pname;
-- Kỳ vọng: dim_employee KHÔNG nằm trong tích Descartes; nó được nối sau cùng
--          (Index Scan / Hash Join theo emp_key) với khoảng 460 dòng sự kiện.


-- #####################################################################
-- TỔNG HỢP (điền vào báo cáo)
--   | Demo | Kế hoạch                        | Dòng sự kiện đọc | Execution Time |
--   | 1    | Seq Scan + Hash Join            | khoảng 1.200.000 | (điền)         |
--   | 2    | Chỉ mục một chiều (dept_key)    | khoảng 24.850    | (điền)         |
--   | 3c   | Biến đổi hình sao (BitmapAnd)   | khoảng 460       | (điền)         |
--   | 4    | Bỏ nối ngược                    | khoảng 460       | (điền)         |
--   | 5a   | Nối hình sao (chỉ mục ghép)     | khoảng 460       | (điền)         |
-- #####################################################################


-- #####################################################################
-- DỌN DẸP (tuỳ chọn)
-- #####################################################################
-- DROP SCHEMA dw CASCADE;
