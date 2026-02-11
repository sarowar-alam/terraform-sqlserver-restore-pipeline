SELECT c.TotalCustomers, o.RecentOrderId, o.OrderAmount
FROM (
    SELECT COUNT(*) AS TotalCustomers 
    FROM tblCustomers
) c
CROSS JOIN (
    SELECT TOP 3 OrderID AS RecentOrderId, TotalAmount AS OrderAmount
    FROM tblOrders
    ORDER BY OrderDate DESC
) o;