select id, status_code, content, created
from net._http_response
order by id desc
limit 3;
