-- =====================================================================
-- KỸ THUẬT 8. TỐI ƯU HOÁ TRUY VẤN PHÂN TÁN – DEMO TRÊN POSTGRESQL
-- Dùng postgres_fdw để mô phỏng 2 trạm trên cùng một PostgreSQL server:
--   Trạm 1 = database company : lưu EMPLOYEE (100.008 dòng)
--   Trạm 2 = database site2   : lưu DEPARTMENT, truy cập EMPLOYEE qua mạng
-- Mọi dữ liệu Trạm 2 lấy từ Trạm 1 đều đi qua kết nối postgres_fdw,
-- giống như truy vấn sang một máy chủ khác.
--
-- CÁCH CHẠY TRONG pgADMIN:
--   Mỗi phần ghi rõ phải chạy trên database nào (company hay site2).
--   Mở Query Tool đúng database đó, bôi đen từng khối rồi bấm F5.
--   Với EXPLAIN (ANALYZE, VERBOSE), dòng quan trọng nhất là "Remote SQL":
--   đó là câu SQL Trạm 2 thực sự gửi sang Trạm 1.
-- =====================================================================


-- #####################################################################
-- PHẦN 0. TẠO TRẠM 2                     (chạy trên database: company)
-- #####################################################################
-- Bôi đen RIÊNG dòng này rồi F5 (CREATE DATABASE không chạy chung với lệnh khác được)
CREATE DATABASE site2;

-- Bảng dùng cho Demo 8.5 (phân mảnh nằm ở Trạm 1)
DROP TABLE IF EXISTS emp_frag_other;
CREATE TABLE emp_frag_other AS
SELECT ssn, fname, lname, dno FROM employee WHERE dno <> 5;


-- #####################################################################
-- PHẦN 1. KẾT NỐI TRẠM 2 VỚI TRẠM 1         (chạy trên database: site2)
-- Trong pgAdmin: chuột phải database site2 -> Query Tool
-- #####################################################################
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Khai báo Trạm 1 (cùng server nên host là localhost)
CREATE SERVER tram1 FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'localhost', port '5432', dbname 'company');

-- Tài khoản dùng để kết nối sang Trạm 1  <-- sửa mật khẩu của bạn
CREATE USER MAPPING FOR CURRENT_USER SERVER tram1
    OPTIONS (user 'postgres', password '123456');

-- Bảng ngoại (foreign table): EMPLOYEE vẫn nằm ở Trạm 1
CREATE SCHEMA tram1;
IMPORT FOREIGN SCHEMA public LIMIT TO (employee, department)
    FROM SERVER tram1 INTO tram1;

-- DEPARTMENT được chép về và lưu thật tại Trạm 2
CREATE TABLE department AS SELECT * FROM tram1.department;
ALTER TABLE department ADD PRIMARY KEY (dnumber);
DROP FOREIGN TABLE tram1.department;

ANALYZE department;
ANALYZE tram1.employee;

-- Kiểm tra: 100008 | 20
SELECT (SELECT count(*) FROM tram1.employee) AS employee_tai_tram1,
       (SELECT count(*) FROM department)     AS department_tai_tram2;


-- #####################################################################
-- DEMO 8.1. CHIẾN LƯỢC TRUYỀN THẲNG          (chạy trên database: site2)
-- Truy vấn Q': tên trưởng phòng của mỗi phòng, gửi tại Trạm 2.
-- Ép dùng Hash Join để Trạm 2 kéo toàn bộ EMPLOYEE về rồi mới nối.
-- #####################################################################
SET enable_nestloop = off;
EXPLAIN (ANALYZE, VERBOSE)
SELECT d.dname, e.fname, e.lname
FROM department d JOIN tram1.employee e ON e.ssn = d.mgr_ssn;
RESET enable_nestloop;
-- Cần chú ý:
--   Foreign Scan on tram1.employee: actual rows = 100008 -> mọi dòng bị gửi qua mạng
--   Remote SQL: SELECT ssn, fname, lname FROM public.employee   (không có WHERE)
--   width = số byte trung bình mỗi dòng
--   => Byte truyền ≈ rows × width
--   Để ý: PostgreSQL đã tự đẩy PHÉP CHIẾU sang Trạm 1 (chỉ lấy 3 cột cần dùng)


-- #####################################################################
-- DEMO 8.2. CHIẾN LƯỢC SEMIJOIN              (chạy trên database: site2)
-- Bước 1: Trạm 2 chiếu cột khoá  π Mgr_ssn (DEPARTMENT)
-- Bước 2: gửi khoá sang Trạm 1, Trạm 1 chỉ trả về nhân viên có ssn khớp
-- Bước 3: Trạm 2 nối kết quả với DEPARTMENT
-- #####################################################################
EXPLAIN (ANALYZE, VERBOSE)
SELECT d.dname, e.fname, e.lname
FROM department d JOIN tram1.employee e ON e.ssn = d.mgr_ssn
WHERE e.ssn = ANY (ARRAY(SELECT mgr_ssn FROM department));
-- Cần chú ý:
--   InitPlan: Seq Scan on department   -> Bước 1, lấy danh sách 20 khoá
--   Remote SQL: ... WHERE ((ssn = ANY ($1::bpchar[])))
--                                       -> Bước 2, khoá được gửi kèm truy vấn
--   Foreign Scan: actual rows = 20     -> chỉ 20 dòng quay về thay vì 100008
--   Hash Join tại Trạm 2               -> Bước 3
--   Byte truyền ≈ 20 khoá × 10 byte + 20 dòng × width
--
-- Nếu Remote SQL KHÔNG có WHERE (phiên bản cũ), dùng cách 2 bước thủ công:
--   SELECT string_agg(quote_literal(mgr_ssn), ', ') FROM department;
--   rồi dán danh sách vào:  ... WHERE e.ssn IN ( <danh sách> );


-- #####################################################################
-- DEMO 8.3. (tuỳ chọn) SEMIJOIN TỪNG DÒNG      (chạy trên database: site2)
-- Nested Loop: với mỗi phòng, gửi một truy vấn nhỏ sang Trạm 1.
-- #####################################################################
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, VERBOSE)
SELECT d.dname, e.fname, e.lname
FROM department d JOIN tram1.employee e ON e.ssn = d.mgr_ssn;
RESET ALL;
-- Cần chú ý: Remote SQL: ... WHERE ((ssn = $1)), loops = 20
--   -> byte truyền rất ít, nhưng phải gửi 20 truy vấn (20 vòng trao đổi mạng).
--   So với 8.2: 8.2 gửi 1 truy vấn chứa cả 20 khoá -> ít vòng trao đổi hơn.


-- #####################################################################
-- DEMO 8.4. KHI NÀO SEMIJOIN KHÔNG HIỆU QUẢ    (chạy trên database: site2)
-- Truy vấn Q: phòng ban của MỌI nhân viên -> gần như mọi dòng đều khớp.
-- #####################################################################
EXPLAIN (ANALYZE, VERBOSE)
SELECT e.fname, e.lname, d.dname
FROM tram1.employee e JOIN department d ON e.dno = d.dnumber
WHERE e.dno = ANY (ARRAY(SELECT dnumber FROM department));
-- Cần chú ý: Foreign Scan vẫn trả về khoảng 100008 dòng.
--   Danh sách khoá chứa cả 20 phòng, mọi nhân viên đều thuộc một trong số đó,
--   nên semijoin không lọc được dòng nào -> không giảm được byte truyền.


-- #####################################################################
-- DEMO 8.5. LOẠI BỎ PHÂN MẢNH NHỜ ĐIỀU KIỆN BẢO VỆ (chạy trên database: site2)
-- EMPLOYEE phân mảnh ngang thành 2 phân mảnh:
--   emp_d5    : guard Dno = 5          lưu tại Trạm 2 (bảng thường)
--   emp_other : guard Dno <> 5 (DEFAULT) lưu tại Trạm 1 (bảng ngoại)
-- Ràng buộc phân vùng của PostgreSQL đóng vai trò điều kiện bảo vệ.
-- #####################################################################
CREATE TABLE emp_frag (
    ssn   CHAR(9),
    fname VARCHAR(10),
    lname VARCHAR(20),
    dno   INT
) PARTITION BY LIST (dno);

CREATE TABLE emp_d5 PARTITION OF emp_frag FOR VALUES IN (5);
INSERT INTO emp_d5
SELECT ssn, fname, lname, dno FROM tram1.employee WHERE dno = 5;

CREATE FOREIGN TABLE emp_other PARTITION OF emp_frag DEFAULT
    SERVER tram1 OPTIONS (table_name 'emp_frag_other');

ANALYZE emp_d5;
ANALYZE emp_other;

-- 8.5a. Có loại bỏ phân mảnh (mặc định)
EXPLAIN (ANALYZE, VERBOSE)
SELECT fname, lname FROM emp_frag WHERE dno = 5;
-- Cần chú ý: chỉ có Seq Scan on emp_d5, KHÔNG có Foreign Scan
--   -> Trạm 1 không bị liên lạc, 0 byte truyền qua mạng.

-- 8.5b. Truy vấn phòng khác: chỉ hỏi Trạm 1, điều kiện được đẩy sang
EXPLAIN (ANALYZE, VERBOSE)
SELECT fname, lname FROM emp_frag WHERE dno = 7;
-- Cần chú ý: chỉ có Foreign Scan on emp_other,
--   Remote SQL: ... WHERE ((dno = 7))  -> Trạm 1 lọc trước rồi mới gửi.

-- 8.5c. Tắt loại bỏ phân mảnh để so sánh
SET enable_partition_pruning = off;
EXPLAIN (ANALYZE, VERBOSE)
SELECT fname, lname FROM emp_frag WHERE dno = 5;
RESET enable_partition_pruning;
-- Cần chú ý: Append gồm cả emp_d5 VÀ Foreign Scan on emp_other
--   -> vẫn gửi truy vấn sang Trạm 1, Trạm 1 phải quét bảng rồi trả về 0 dòng.
--   So sánh Execution Time với 8.5a.


-- #####################################################################
-- DỌN DẸP (tuỳ chọn)
-- #####################################################################
-- Trên database company:  DROP DATABASE site2;  DROP TABLE emp_frag_other;
