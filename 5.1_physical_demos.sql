-- =====================================================================
-- MỤC 5. TỐI ƯU HOÁ CẤP ĐỘ VẬT LÝ & KỸ THUẬT XỬ LÝ LUỒNG
-- Các demo trên PostgreSQL (CSDL company, đã chạy file 01 và 02)
--
-- CÁCH CHẠY TRONG pgADMIN:
--   Bôi đen TỪNG KHỐI (hoặc từng câu EXPLAIN) rồi bấm F5.
--   Không chạy cả file một lần, vì pgAdmin chỉ hiện kết quả câu cuối.
--   Chạy mỗi câu EXPLAIN 2-3 lần, lấy kết quả ổn định để đưa vào báo cáo.
--   Sau mỗi khối có SET ..., luôn chạy RESET ALL; trước khi sang khối khác.
-- =====================================================================


-- #####################################################################
-- DEMO 1. ĐƯỜNG TRUY XUẤT VÀ ĐỘ CHỌN LỌC (mục 5.1) - đã làm, phần bổ sung
-- #####################################################################

-- 1.0. (Chỉ chạy khi muốn làm lại Demo 1 từ đầu)
-- DROP INDEX IF EXISTS idx_emp_salary;
-- DROP INDEX IF EXISTS idx_emp_lname_hash;

-- 1.4b. ÉP dùng chỉ mục cho điều kiện chọn lọc thấp để chứng minh
--       bộ tối ưu đã chọn đúng khi dùng Seq Scan ở Bước 4.
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employee WHERE salary > 30000;
RESET ALL;
-- Kỳ vọng: chi phí ước lượng > 2582.10, số trang đọc > 1332.

-- 1.5c. Hash index không hỗ trợ so sánh khoảng
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employee WHERE lname = 'Smith';  -- dùng hash index
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employee WHERE lname > 'W';      -- Seq Scan

-- 1.6. CLUSTERING INDEX: sắp xếp lại vật lý bảng theo salary
--      Trước khi CLUSTER, câu salary = 50000 đọc khoảng 789 trang (Bước 3).
CLUSTER employee USING idx_emp_salary;
ANALYZE employee;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM employee WHERE salary = 50000;
-- Kỳ vọng: các dòng lương 50000 nằm liền nhau -> chỉ đọc khoảng 16-20 trang,
-- thường chuyển sang Index Scan. So sánh Heap Blocks / Buffers với Bước 3.
-- Ghi chú: CLUSTER sắp xếp một lần; dữ liệu thêm sau đó không tự giữ thứ tự.


-- #####################################################################
-- DEMO 2. GIẢI THUẬT NỐI (mục 5.1)
-- Cùng một câu truy vấn, ép PostgreSQL dùng lần lượt từng giải thuật.
-- Câu dùng chung: nhân viên phòng 7 có lương >= 95000 và các dự án họ tham gia
-- (khoảng 125 nhân viên, khoảng 250 dòng kết quả).
-- #####################################################################

-- 2a. Mặc định: bộ tối ưu tự chọn
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 7 AND e.salary >= 95000;

-- 2b. Index Nested-Loop Join: với mỗi nhân viên, tra chỉ mục khoá chính
--     (essn, pno) của works_on
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 7 AND e.salary >= 95000;
RESET ALL;

-- 2c. Nested-Loop Join thuần (không chỉ mục): với mỗi nhân viên,
--     duyệt lại toàn bộ works_on. Chạy chậm (vài giây) - đó là điều cần thấy.
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 7 AND e.salary >= 95000;
RESET ALL;
-- Để ý: nút bên trong có loops = số nhân viên, Rows Removed by Join rất lớn.

-- 2d. Sort-Merge Join: sắp hai bên theo khoá nối rồi trộn
SET enable_hashjoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 7 AND e.salary >= 95000;
RESET ALL;

-- 2e. Hash Join (ép rõ ràng để so sánh)
SET enable_nestloop = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 7 AND e.salary >= 95000;
RESET ALL;

-- 2f. PARTITION-HASH JOIN: hash join khi thiếu RAM
--     Nối toàn bộ hai bảng; bảng băm dựng trên employee (100.008 dòng).
SET work_mem = '64kB';                  -- RAM rất ít (mức tối thiểu)
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM employee e JOIN works_on w ON e.ssn = w.essn;
RESET ALL;
-- Kỳ vọng: nút Hash có "Batches: 32" (hoặc lớn hơn 1) và Buffers có temp read/written
-- -> dữ liệu bị chia thành nhiều phần ghi ra đĩa = Partition-Hash Join.

SET work_mem = '64MB';                  -- RAM đủ
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM employee e JOIN works_on w ON e.ssn = w.essn;
RESET ALL;
-- Kỳ vọng: "Batches: 1", không có temp -> bảng băm nằm trọn trong RAM.


-- #####################################################################
-- DEMO 3. CẤU TRÚC CÂY NỐI (mục 5.1)
-- Nối 4 bảng. Vẽ lại cây kế hoạch từ kết quả EXPLAIN.
-- #####################################################################

EXPLAIN (ANALYZE)
SELECT e.lname, p.pname, d.dname, w.hours
FROM employee e
JOIN works_on   w ON e.ssn     = w.essn
JOIN project    p ON w.pno     = p.pnumber
JOIN department d ON p.dnum    = d.dnumber
WHERE e.dno = 7 AND e.salary >= 95000;
-- Cách đọc: mỗi nút Join có 2 con. Nếu con bên TRONG (thứ hai) của mọi
-- phép nối đều là bảng gốc (Seq Scan / Index Scan / Hash trên bảng gốc),
-- còn kết quả phép nối trước luôn đi vào nhánh NGOÀI (thứ nhất), thì đó là
-- cây lệch trái (left-deep).
-- Lưu ý: PostgreSQL in Hash Join với nhánh "Hash" là bên dựng bảng băm.


-- #####################################################################
-- DEMO 4. XỬ LÝ LUỒNG VÀ VẬT LÝ HOÁ (mục 5.2)
-- #####################################################################

-- 4a. Luồng + LIMIT: chỉ xử lý vài dòng rồi dừng
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
LIMIT 10;
-- Để ý cột rows thực tế của các nút con: rất nhỏ so với kích thước bảng.

-- 4b. Toán tử chặn (Sort) làm đứt luồng: phải đọc hết mới trả được dòng đầu
EXPLAIN (ANALYZE, BUFFERS)
SELECT e.lname, w.pno, w.hours
FROM employee e JOIN works_on w ON e.ssn = w.essn
ORDER BY w.hours
LIMIT 10;
-- So sánh Execution Time và rows của các nút con với 4a.

-- 4c. Vật lý hoá kết quả trung gian xuống đĩa khi sắp xếp thiếu RAM
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM works_on ORDER BY hours;
RESET ALL;
-- Kỳ vọng: "Sort Method: external merge  Disk: ...kB" -> ghi tệp tạm.

SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM works_on ORDER BY hours;
RESET ALL;
-- Kỳ vọng: "Sort Method: quicksort  Memory: ...kB" -> xử lý trong RAM.

-- 4d. CTE vật lý hoá và CTE dạng luồng
--     MATERIALIZED: tính hết kết quả CTE vào bảng tạm rồi mới dùng
EXPLAIN (ANALYZE, BUFFERS)
WITH e AS MATERIALIZED (SELECT * FROM employee)
SELECT * FROM e WHERE ssn = '123456789';
--     NOT MATERIALIZED: CTE được gộp vào truy vấn chính, dòng chảy thẳng,
--     điều kiện được đẩy xuống và dùng được chỉ mục khoá chính
EXPLAIN (ANALYZE, BUFFERS)
WITH e AS NOT MATERIALIZED (SELECT * FROM employee)
SELECT * FROM e WHERE ssn = '123456789';
-- So sánh: CTE Scan đọc 100.008 dòng vs Index Scan đọc 1 dòng.

-- 4e. Vật lý hoá thủ công bằng bảng tạm vs một truy vấn dạng luồng
--     Cách 1 gồm 2 bước, thời gian = tổng 2 Execution Time
EXPLAIN (ANALYZE, BUFFERS)
CREATE TEMP TABLE tmp_emp AS SELECT * FROM employee WHERE dno = 5;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM tmp_emp t JOIN works_on w ON t.ssn = w.essn;

DROP TABLE tmp_emp;

--     Cách 2: một truy vấn
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM employee e JOIN works_on w ON e.ssn = w.essn
WHERE e.dno = 5;


-- 4f. VÍ DỤ TRONG SÁCH: (EMPLOYEE ⨝ DEPARTMENT) ⨝ PROJECT
--     So sánh vật lý hoá kết quả phép nối 1 và xử lý luồng.
--
--     QUAN TRỌNG: mở một Query Tool MỚI và chạy lệnh SET temp_buffers dưới đây
--     TRƯỚC khi tạo bất kỳ bảng tạm nào. Nếu không, bảng tạm (khoảng 5-6 MB)
--     nằm gọn trong bộ đệm RAM 8 MB mặc định và không thấy được việc ghi đĩa.
SET temp_buffers = '1MB';

-- ---------- Cách 1: VẬT LÝ HOÁ ----------
-- Bước 1: phép nối 1, ghi toàn bộ kết quả ra bảng tạm (tệp tạm)
EXPLAIN (ANALYZE, BUFFERS)
CREATE TEMP TABLE tmp_emp_dept AS
SELECT e.ssn, e.lname, e.dno, d.dname
FROM employee e JOIN department d ON e.dno = d.dnumber;
-- Để ý dòng Buffers: "local ... written=..." = số block ghi xuống đĩa.

-- Kích thước tệp tạm: số dòng và số block (1 block = 8 KB)
SELECT count(*)                                  AS so_dong,
       pg_relation_size('tmp_emp_dept') / 8192   AS so_block
FROM tmp_emp_dept;

-- Bước 2: phép nối 2 đọc lại kết quả trung gian từ bảng tạm
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM tmp_emp_dept t JOIN project p ON t.dno = p.dnum;
-- Để ý dòng Buffers: "local read=..." = số block đọc lại.

DROP TABLE tmp_emp_dept;

-- ---------- Cách 2: XỬ LÝ LUỒNG ----------
-- join_collapse_limit = 1 buộc PostgreSQL nối đúng thứ tự viết
-- (EMPLOYEE ⨝ DEPARTMENT trước, rồi mới ⨝ PROJECT) cho giống ví dụ sách.
SET join_collapse_limit = 1;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM employee e
JOIN department d ON e.dno = d.dnumber
JOIN project    p ON d.dnumber = p.dnum;
RESET join_collapse_limit;
-- Để ý: KHÔNG có "local written" hay "temp written": kết quả phép nối 1
-- được chuyển thẳng lên phép nối 2 trong RAM, không ghi tệp trung gian.
--
-- So sánh:
--   I/O thêm của vật lý hoá = block ghi (Bước 1) + block đọc lại (Bước 2)
--                           ≈ 2 × so_block   (đúng công thức ví dụ trong sách)
--   Thời gian vật lý hoá     = Execution Time Bước 1 + Bước 2
--   Thời gian xử lý luồng    = Execution Time Cách 2


-- #####################################################################
-- DỌN DẸP (tuỳ chọn)
-- #####################################################################
RESET ALL;
-- DROP INDEX IF EXISTS idx_emp_salary;
-- DROP INDEX IF EXISTS idx_emp_lname_hash;
