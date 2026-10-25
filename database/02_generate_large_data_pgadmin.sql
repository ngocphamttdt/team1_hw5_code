-- =====================================================================
-- EMPLOYEE DATABASE - SINH DỮ LIỆU LỚN ĐỂ THỬ NGHIỆM TỐI ƯU TRUY VẤN
-- BẢN CHO pgADMIN / DBEAVER: mở bằng Query Tool, chạy SAU file 01, bấm Execute (F5)
--
-- Kết quả mặc định (đổi được ở phần tham số):
--   EMPLOYEE       : 8 dòng gốc + 100.000 dòng sinh thêm
--   WORKS_ON       : 16 dòng gốc + khoảng 200.000 dòng (mỗi NV 1-3 dự án)
--   DEPENDENT      : 7 dòng gốc + khoảng 45.000 dòng (30% NV có 1-2 người phụ thuộc)
--   DEPARTMENT     : 3 phòng gốc + 17 phòng mới (tổng 20)
--   DEPT_LOCATIONS : thêm 1 địa điểm cho mỗi phòng mới
--   PROJECT        : 6 dự án gốc + 500 dự án mới
--
-- Dữ liệu được cố ý làm LỆCH để thấy rõ tác dụng của bộ tối ưu:
--   - 40% nhân viên thuộc phòng 5, 20% thuộc phòng 4, còn lại rải đều 20 phòng
--   - Dự án số nhỏ có nhiều người tham gia hơn hẳn dự án số lớn
--   - Lương từ 20.000 đến 99.000 (vừa kiểu DECIMAL(5) của script gốc)
--
-- Quy ước để phân biệt với dữ liệu gốc:
--   - SSN sinh thêm: 500000001 .. 500000000 + n_emp
--   - Dự án sinh thêm: Pnumber > 1000
--   - Phòng sinh thêm: Dnumber khác 1, 4, 5
-- File chạy lại được nhiều lần; dữ liệu gốc của sách luôn được giữ nguyên.
-- Không tạo thêm index nào ngoài khoá chính/UNIQUE, để tự tạo khi demo.
-- =====================================================================

-- Muốn đổi số lượng: thay 100000 (số nhân viên) và 500 (số dự án) trong file
-- ---------------------------------------------------------------------


BEGIN;

-- ---------------------------------------------------------------------
-- 0. Xoá dữ liệu sinh ở lần chạy trước (theo đúng thứ tự khoá ngoại)
-- ---------------------------------------------------------------------
DELETE FROM works_on  WHERE essn BETWEEN '500000001' AND '599999999' OR pno > 1000;
DELETE FROM dependent WHERE essn BETWEEN '500000001' AND '599999999';
UPDATE department SET mgr_ssn = '888665555' WHERE dnumber NOT IN (1, 4, 5);
DELETE FROM employee  WHERE ssn  BETWEEN '500000001' AND '599999999';
DELETE FROM project   WHERE pnumber > 1000;
DELETE FROM dept_locations WHERE dnumber NOT IN (1, 4, 5);
DELETE FROM department     WHERE dnumber NOT IN (1, 4, 5);

-- Cố định bộ sinh số ngẫu nhiên: ai chạy cũng ra cùng một bộ dữ liệu
SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- 1. Phòng ban mới: 2, 3, 6..20 (trưởng phòng tạm là James Borg)
-- ---------------------------------------------------------------------
INSERT INTO department (dname, dnumber, mgr_ssn, mgr_start_date)
SELECT 'Dept_' || lpad(d::text, 2, '0'),
       d,
       '888665555',
       DATE '2000-01-01' + floor(random() * 8000)::int
FROM generate_series(2, 20) AS d
WHERE d NOT IN (4, 5);

INSERT INTO dept_locations (dnumber, dlocation)
SELECT dnumber,
       (ARRAY['Houston','Bellaire','Sugarland','Stafford','Spring','Humble','Katy'])
           [1 + dnumber % 7]
FROM department
WHERE dnumber NOT IN (1, 4, 5);

-- ---------------------------------------------------------------------
-- 2. Dự án mới: 1001 .. 1000 + n_proj
-- ---------------------------------------------------------------------
INSERT INTO project (pname, pnumber, plocation, dnum)
SELECT 'Project_' || lpad(p::text, 5, '0'),
       1000 + p,
       (ARRAY['Houston','Bellaire','Sugarland','Stafford','Spring','Humble','Katy'])
           [1 + floor(random() * 7)::int],
       1 + floor(random() * 20)::int
FROM generate_series(1, 500) AS p;

-- ---------------------------------------------------------------------
-- 3. Nhân viên mới
--    Người giám sát của nhân viên i là nhân viên i/20 (cây quản lý nhiều cấp);
--    20 nhân viên đầu tiên do James Borg giám sát.
-- ---------------------------------------------------------------------
INSERT INTO employee (fname, minit, lname, ssn, bdate, address, sex, salary, super_ssn, dno)
SELECT
    (ARRAY['John','Franklin','Alicia','Jennifer','Ramesh','Joyce','Ahmad','James',
           'Mary','Robert','Linda','Michael','Susan','David','Karen','Daniel',
           'Nancy','Paul','Lisa','Mark'])[1 + floor(random() * 20)::int],
    chr(65 + floor(random() * 26)::int),
    (ARRAY['Smith','Wong','Zelaya','Wallace','Narayan','English','Jabbar','Borg',
           'Johnson','Brown','Davis','Miller','Wilson','Moore','Taylor','Anderson',
           'Thomas','Jackson','White','Harris'])[1 + floor(random() * 20)::int],
    (500000000 + g.i)::text,
    DATE '1960-01-01' + floor(random() * 14600)::int,               -- sinh 1960-1999
    left(
        (1 + floor(random() * 9999)::int)::text || ' ' ||
        (ARRAY['Fondren','Voss','Castle','Berry','Fire Oak','Rice','Dallas','Stone',
               'Main','Elm','Kirby','Shepherd'])[1 + floor(random() * 12)::int] || ', ' ||
        (ARRAY['Houston','Bellaire','Sugarland','Stafford','Spring','Humble','Katy'])
            [1 + floor(random() * 7)::int] || ' TX',
        30),
    CASE WHEN random() < 0.5 THEN 'M' ELSE 'F' END,
    20000 + floor(random() * 80)::int * 1000,                       -- 20.000 - 99.000
    CASE WHEN g.i <= 20 THEN '888665555'
         ELSE (500000000 + g.i / 20)::text END,
    CASE WHEN g.r < 0.40 THEN 5                                     -- 40% phòng 5
         WHEN g.r < 0.60 THEN 4                                     -- 20% phòng 4
         ELSE 1 + floor(random() * 20)::int END                     -- còn lại rải đều
FROM (SELECT i, random() AS r FROM generate_series(1, 100000) AS i) AS g;

-- ---------------------------------------------------------------------
-- 4. WORKS_ON: mỗi nhân viên mới tham gia 1-3 dự án khác nhau
--    base = n_proj * random()^2 -> dự án số nhỏ đông người hơn (dữ liệu lệch)
-- ---------------------------------------------------------------------
INSERT INTO works_on (essn, pno, hours)
WITH emp_rand AS MATERIALIZED (
    SELECT i,
           floor(500 * random() ^ 2)::int AS base,
           1 + floor(random() * 3)::int       AS cnt
    FROM generate_series(1, 100000) AS i
)
SELECT (500000000 + e.i)::text,
       1001 + (e.base + k * 101) % 500,
       round((1 + random() * 39)::numeric, 1)                       -- 1.0 - 40.0 giờ
FROM emp_rand AS e
CROSS JOIN LATERAL generate_series(1, e.cnt) AS k;

-- ---------------------------------------------------------------------
-- 5. DEPENDENT: khoảng 30% nhân viên mới có 1-2 người phụ thuộc
-- ---------------------------------------------------------------------
INSERT INTO dependent (essn, dependent_name, sex, bdate, relationship)
WITH dep_rand AS MATERIALIZED (
    SELECT i,
           floor(random() * 10)::int     AS base,
           1 + floor(random() * 2)::int  AS cnt
    FROM generate_series(1, 100000) AS i
    WHERE random() < 0.30
)
SELECT (500000000 + d.i)::text,
       (ARRAY['Alice','Theodore','Joy','Abner','Michael','Elizabeth',
              'Emma','Oliver','Sophia','Lucas'])[1 + (d.base + k) % 10],
       CASE WHEN random() < 0.5 THEN 'M' ELSE 'F' END,
       DATE '1960-01-01' + floor(random() * 20000)::int,
       (ARRAY['Spouse','Son','Daughter'])[1 + floor(random() * 3)::int]
FROM dep_rand AS d
CROSS JOIN LATERAL generate_series(1, d.cnt) AS k;

-- ---------------------------------------------------------------------
-- 6. Trưởng phòng của các phòng mới = nhân viên lương cao nhất trong phòng
-- ---------------------------------------------------------------------
UPDATE department AS d
SET mgr_ssn = m.ssn
FROM (
    SELECT DISTINCT ON (dno) dno, ssn
    FROM employee
    WHERE ssn BETWEEN '500000001' AND '599999999'
    ORDER BY dno, salary DESC, ssn
) AS m
WHERE d.dnumber = m.dno
  AND d.dnumber NOT IN (1, 4, 5);

COMMIT;

-- ---------------------------------------------------------------------
-- 7. Cập nhật thống kê cho bộ tối ưu (bắt buộc trước khi chạy EXPLAIN)
-- ---------------------------------------------------------------------
ANALYZE;


-- ---------------------------------------------------------------------
-- 8. Kiểm tra kết quả
-- ---------------------------------------------------------------------
SELECT (SELECT count(*) FROM employee)       AS employee,
       (SELECT count(*) FROM department)     AS department,
       (SELECT count(*) FROM dept_locations) AS dept_locations,
       (SELECT count(*) FROM project)        AS project,
       (SELECT count(*) FROM works_on)       AS works_on,
       (SELECT count(*) FROM dependent)      AS dependent;

-- Phân bố nhân viên theo phòng: thấy rõ phòng 5 và 4 chiếm đa số
SELECT dno,
       count(*) AS so_nhan_vien,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS phan_tram
FROM employee
GROUP BY dno
ORDER BY so_nhan_vien DESC
LIMIT 5;
