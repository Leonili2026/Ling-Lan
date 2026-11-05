BEGIN;
ALTER TABLE public.restaurant_kitchen ADD COLUMN initial_lines jsonb;
UPDATE public.restaurant_kitchen SET initial_lines=lines;
CREATE FUNCTION public.restaurant_keep_initial_lines() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN NEW.initial_lines:=NEW.lines; RETURN NEW; END;
$$;
REVOKE ALL ON FUNCTION public.restaurant_keep_initial_lines() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_restaurant_keep_initial BEFORE INSERT ON public.restaurant_kitchen
FOR EACH ROW EXECUTE FUNCTION public.restaurant_keep_initial_lines();

CREATE TABLE public.restaurant_addons (
 id uuid PRIMARY KEY, ticket_id uuid NOT NULL REFERENCES public.restaurant_kitchen(id),
 requested jsonb NOT NULL, lines jsonb NOT NULL,
 status text NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','preparing','served')),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.restaurant_addons ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.restaurant_addons FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.restaurant_addons TO authenticated;
CREATE POLICY restaurant_addons_read ON public.restaurant_addons FOR SELECT TO authenticated
 USING ((SELECT public.restaurant_has_role()));

CREATE FUNCTION public.restaurant_add_items(ticket_id uuid,request_id uuid,requested jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 ticket public.restaurant_kitchen; prior public.restaurant_addons; entry record;
 current_line jsonb; new_line jsonb; merged jsonb; delta jsonb:='[]'::jsonb;
 all_lines jsonb; all_items jsonb; quantity integer;
BEGIN
 IF NOT public.restaurant_is_cashier() THEN RAISE EXCEPTION '需要櫃台權限' USING ERRCODE='42501'; END IF;
 IF ticket_id IS NULL OR request_id IS NULL OR jsonb_typeof(requested) IS DISTINCT FROM 'object' OR requested='{}'::jsonb THEN
   RAISE EXCEPTION '請選擇加點餐點' USING ERRCODE='22023';
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(ticket_id::text,0));
 SELECT * INTO prior FROM public.restaurant_addons a WHERE a.id=request_id;
 IF FOUND THEN
   IF prior.ticket_id IS DISTINCT FROM ticket_id OR prior.requested IS DISTINCT FROM requested THEN
     RAISE EXCEPTION '加點編號已使用' USING ERRCODE='22023';
   END IF;
   RETURN prior.id;
 END IF;
 SELECT * INTO ticket FROM public.restaurant_kitchen k WHERE k.id=ticket_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '找不到桌單，請重新整理' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurant_sales s WHERE s.id=ticket_id) THEN
   RAISE EXCEPTION '此桌已結帳，請重新開單' USING ERRCODE='23505';
 END IF;
 all_lines:=public.restaurant_ticket_lines(ticket);
 all_items:=ticket.items;
 FOR entry IN SELECT e.key,e.value,m.name,m.price FROM jsonb_each(requested) e
   LEFT JOIN public.restaurant_menu m ON m.id=e.key AND m.active
 LOOP
   IF entry.name IS NULL OR jsonb_typeof(entry.value)<>'number' OR entry.value::text !~ '^[1-9][0-9]?$' THEN
     RAISE EXCEPTION '加點餐點已下架或份數無效' USING ERRCODE='22023';
   END IF;
   quantity:=(entry.value::text)::int;
   SELECT value INTO current_line FROM jsonb_array_elements(all_lines) WHERE value->>'id'=entry.key;
   IF FOUND THEN
     IF (current_line->>'qty')::int+quantity>99 THEN RAISE EXCEPTION '單一餐點總份數不可超過 99' USING ERRCODE='22023'; END IF;
     new_line:=current_line||jsonb_build_object('qty',quantity);
     SELECT jsonb_agg(CASE WHEN value->>'id'=entry.key THEN
       value||jsonb_build_object('qty',(value->>'qty')::int+quantity) ELSE value END)
     INTO merged FROM jsonb_array_elements(all_lines);
     all_lines:=merged;
   ELSE
     new_line:=jsonb_build_object('id',entry.key,'name',entry.name,'price',entry.price,'qty',quantity);
     all_lines:=all_lines||jsonb_build_array(new_line);
   END IF;
   delta:=delta||jsonb_build_array(new_line);
   all_items:=all_items||jsonb_build_object(entry.key,coalesce((all_items->>entry.key)::int,0)+quantity);
 END LOOP;
 INSERT INTO public.restaurant_addons(id,ticket_id,requested,lines) VALUES(request_id,ticket_id,requested,delta);
 UPDATE public.restaurant_kitchen k SET items=all_items,lines=all_lines WHERE k.id=ticket_id;
 RETURN request_id;
END;
$$;
REVOKE ALL ON FUNCTION public.restaurant_add_items(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.restaurant_add_items(uuid,uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.restaurant_open_tables()
RETURNS TABLE(id uuid,service text,table_label text,status text,created_at timestamptz,lines jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT k.id,k.service,k.table_label,
   CASE WHEN k.status='queued' OR EXISTS(SELECT 1 FROM public.restaurant_addons a WHERE a.ticket_id=k.id AND a.status='queued') THEN 'queued'
        WHEN k.status='preparing' OR EXISTS(SELECT 1 FROM public.restaurant_addons a WHERE a.ticket_id=k.id AND a.status='preparing') THEN 'preparing'
        ELSE 'served' END,
   k.created_at,public.restaurant_ticket_lines(k)
 FROM public.restaurant_kitchen k WHERE public.restaurant_is_cashier()
 AND NOT EXISTS(SELECT 1 FROM public.restaurant_sales s WHERE s.id=k.id) ORDER BY k.created_at
$$;

CREATE FUNCTION public.restaurant_kitchen_batches()
RETURNS TABLE(id uuid,source text,service text,table_label text,lines jsonb,status text,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT k.id,'original'::text,k.service,k.table_label,coalesce(k.initial_lines,k.lines),k.status,k.created_at
 FROM public.restaurant_kitchen k WHERE public.restaurant_has_role() AND
   (k.status<>'served' OR k.created_at>=(now() AT TIME ZONE 'Asia/Taipei')::date AT TIME ZONE 'Asia/Taipei')
 UNION ALL
 SELECT a.id,'addon'::text,k.service,k.table_label,a.lines,a.status,a.created_at
 FROM public.restaurant_addons a JOIN public.restaurant_kitchen k ON k.id=a.ticket_id
 WHERE public.restaurant_has_role() AND
   (a.status<>'served' OR a.created_at>=(now() AT TIME ZONE 'Asia/Taipei')::date AT TIME ZONE 'Asia/Taipei')
 ORDER BY created_at DESC
$$;
REVOKE ALL ON FUNCTION public.restaurant_kitchen_batches() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.restaurant_kitchen_batches() TO authenticated;

CREATE FUNCTION public.restaurant_batch_status(batch_id uuid,batch_source text,old_status text,new_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE changed integer;
BEGIN
 IF NOT public.restaurant_has_role() THEN RAISE EXCEPTION '需要員工權限' USING ERRCODE='42501'; END IF;
 IF NOT ((old_status='queued' AND new_status='preparing') OR (old_status='preparing' AND new_status='served')) THEN
   RAISE EXCEPTION '出餐狀態無效' USING ERRCODE='22023';
 END IF;
 IF batch_source='original' THEN
   UPDATE public.restaurant_kitchen SET status=new_status WHERE id=batch_id AND status=old_status;
 ELSIF batch_source='addon' THEN
   UPDATE public.restaurant_addons SET status=new_status WHERE id=batch_id AND status=old_status;
 ELSE RAISE EXCEPTION '出餐單類型無效' USING ERRCODE='22023';
 END IF;
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>1 THEN RAISE EXCEPTION '出餐狀態已更新，請重新整理' USING ERRCODE='40001'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.restaurant_batch_status(uuid,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.restaurant_batch_status(uuid,text,text,text) TO authenticated;
COMMIT;
