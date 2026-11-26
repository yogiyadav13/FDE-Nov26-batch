
-- to fetch all the rows from order table
SELECT * from Orders;

Select * from support_cases;
Select * from human_reviews;

-- Count all the rows in orders table
Select COUNT(*) from orders;
Select count(order_date) from ORDERS;

-- where clause is used to filter the rows on a particular condition 
Select * from orders where order_id = 'MR-000003';

-- Show the data where payment status is paid
Select * from orders where payment_status = 'paid';

-- Count the number of entries where payment status is paid
Select Count(*) from orders where payment_status = 'paid';

--  Get all the orders which were placed after 15th March, 2026
select * from orders where order_date > "2026-03-15";

--  Get all the orders which has delivery date as null
select * from orders where delivery_date IS NULL;

-- give the order_id, product, order_date and delivery_date of each order then we have sorted 
-- them in descending order, and looked at the top 5.
select order_id, product, order_date, delivery_date from orders
Order by Order_id desc
LIMIT 5;

Select * from support_cases;

-- Get all the pending cases which are of type delivery or billing
select * from support_cases 
where review_status ='PENDING'
AND (case_type ='DELIVERY' or case_type ='BILLING');

select * from support_cases 
where review_status ='PENDING'
AND case_type IN ('DELIVERY' , 'BILLING');



-- cond1 (cond2 cond3)

Select * from Human_reviews;

Select Count(*) from Human_reviews;
Select DISTINCT(Count(review_id)) from Human_reviews;
SELECT count(distinct review_id) FROM human_reviews;


-- Homework

-- Return the ten most recently received PENDING support cases.
-- Count orders by payment_status and sort the largest group first.
-- Return issue types that appear more than 2500 times in issue_records.
-- Show review-event count, distinct reviewed-case count, and average handling_minutes, grouped by reviewer_role.
-- Return review_id, case_id, decision and reviewed_at for every review event where triggered_rule_id = 'VR-006'.
-- In one sentence, explain why task 5 still cannot tell you the issue type of those cases without touching a second table.




