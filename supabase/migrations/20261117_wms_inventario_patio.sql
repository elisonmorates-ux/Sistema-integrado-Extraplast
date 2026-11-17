-- Inventário físico exclusivo do estoque Pátio (PA).
ALTER TABLE public.inventario_wms_posicoes
  DROP CONSTRAINT IF EXISTS inventario_wms_posicoes_tipo_estoque_check;
ALTER TABLE public.inventario_wms_posicoes
  ADD CONSTRAINT inventario_wms_posicoes_tipo_estoque_check
  CHECK (tipo_estoque = ANY (ARRAY['PRODUTO_PRONTO'::text,'MATERIA_PRIMA'::text,'PATIO'::text]));

CREATE OR REPLACE FUNCTION public.registrar_posicao_inventario_pa(p_inventario_id bigint,p_endereco_wms_id bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $function$
DECLARE v_status text; v_local_id bigint; v_local_codigo text; v_pos_status text;
BEGIN
 SELECT status INTO v_status FROM public.inventarios_wms WHERE id=p_inventario_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inventário não encontrado'; END IF;
 IF v_status<>'ABERTO' THEN RAISE EXCEPTION 'O inventário não está aberto'; END IF;
 SELECT e.local_id,upper(l.codigo) INTO v_local_id,v_local_codigo FROM public.enderecos_wms e JOIN public.locais_estoque l ON l.id=e.local_id WHERE e.id=p_endereco_wms_id AND e.ativo IS DISTINCT FROM false;
 IF NOT FOUND OR v_local_codigo<>'PA' THEN RAISE EXCEPTION 'Selecione uma posição ativa do estoque PA'; END IF;
 INSERT INTO public.inventario_wms_posicoes(inventario_id,endereco_wms_id,tipo_estoque) VALUES(p_inventario_id,p_endereco_wms_id,'PATIO') ON CONFLICT(inventario_id,endereco_wms_id,tipo_estoque) DO NOTHING;
 SELECT status INTO v_pos_status FROM public.inventario_wms_posicoes WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO' FOR UPDATE;
 IF v_pos_status='APROVADO' THEN RAISE EXCEPTION 'Esta posição já foi aprovada neste inventário'; END IF;
 RETURN jsonb_build_object('ok',true,'status','EM_CONTAGEM','inventario_id',p_inventario_id,'endereco_wms_id',p_endereco_wms_id,'tipo_estoque','PATIO');
END; $function$;

CREATE OR REPLACE FUNCTION public.registrar_contagem_inventario_pa(p_inventario_id bigint,p_endereco_wms_id bigint,p_estoque_pa_id bigint,p_lote text,p_quantidade numeric,p_observacao text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $function$
DECLARE v_local_id bigint; v_lote text; v_id bigint;
BEGIN
 IF p_quantidade IS NULL OR p_quantidade<0 THEN RAISE EXCEPTION 'A quantidade contada não pode ser negativa'; END IF;
 SELECT e.local_id,upper(l.codigo) INTO v_local_id,v_lote FROM public.enderecos_wms e JOIN public.locais_estoque l ON l.id=e.local_id WHERE e.id=p_endereco_wms_id AND e.ativo IS DISTINCT FROM false;
 IF NOT FOUND OR v_lote<>'PA' THEN RAISE EXCEPTION 'Posição informada não pertence ao PA'; END IF;
 PERFORM public.registrar_posicao_inventario_pa(p_inventario_id,p_endereco_wms_id);
 SELECT lote INTO v_lote FROM public.estoque_pa WHERE id=p_estoque_pa_id AND local_id=v_local_id AND (endereco_wms_id IS NULL OR endereco_wms_id=p_endereco_wms_id) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado no estoque PA ou já endereçado em outra posição'; END IF;
 IF coalesce(v_lote,'')<>coalesce(p_lote,'') THEN RAISE EXCEPTION 'O lote do item foi alterado. Atualize a tela e tente novamente.'; END IF;
 SELECT id INTO v_id FROM public.inventario_wms_itens WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO' AND item_id=p_estoque_pa_id AND coalesce(lote,'')=coalesce(p_lote,'') ORDER BY id LIMIT 1 FOR UPDATE;
 IF v_id IS NULL THEN
  INSERT INTO public.inventario_wms_itens(inventario_id,endereco_wms_id,tipo_estoque,item_id,lote,quantidade_contada,observacao,status) VALUES(p_inventario_id,p_endereco_wms_id,'PATIO',p_estoque_pa_id,nullif(p_lote,''),p_quantidade,p_observacao,'PENDENTE') RETURNING id INTO v_id;
 ELSE
  UPDATE public.inventario_wms_itens SET quantidade_contada=coalesce(quantidade_contada,0)+p_quantidade,observacao=CASE WHEN nullif(btrim(coalesce(p_observacao,'')),'') IS NULL THEN observacao WHEN nullif(btrim(coalesce(observacao,'')),'') IS NULL THEN p_observacao ELSE observacao||' | '||p_observacao END,status='PENDENTE',aprovado_em=NULL,quantidade_sistema=NULL,diferenca=NULL,contado_em=now() WHERE id=v_id;
 END IF;
 RETURN jsonb_build_object('ok',true,'contagem_id',v_id,'quantidade_adicionada',p_quantidade);
END; $function$;

CREATE OR REPLACE FUNCTION public.registrar_posicao_vazia_inventario_pa(p_inventario_id bigint,p_endereco_wms_id bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $function$
BEGIN
 IF EXISTS(SELECT 1 FROM public.inventario_wms_itens WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO') THEN RAISE EXCEPTION 'Esta posição já possui itens registrados. Não é possível marcá-la como vazia.'; END IF;
 RETURN public.registrar_posicao_inventario_pa(p_inventario_id,p_endereco_wms_id);
END; $function$;

CREATE OR REPLACE FUNCTION public.aprovar_posicao_inventario_pa(p_inventario_id bigint,p_endereco_wms_id bigint)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $function$
DECLARE v_inv_status text; v_inv_codigo text; v_local_id bigint; v_local_codigo text; v_pos_status text; r record; v_diff numeric; v_grupos integer:=0; v_zerados integer:=0; v_qtd_zerada numeric:=0;
BEGIN
 SELECT status,codigo INTO v_inv_status,v_inv_codigo FROM public.inventarios_wms WHERE id=p_inventario_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Inventário não encontrado'; END IF;
 IF v_inv_status<>'ABERTO' THEN RAISE EXCEPTION 'O inventário não está aberto'; END IF;
 SELECT e.local_id,upper(l.codigo) INTO v_local_id,v_local_codigo FROM public.enderecos_wms e JOIN public.locais_estoque l ON l.id=e.local_id WHERE e.id=p_endereco_wms_id AND e.ativo IS DISTINCT FROM false;
 IF NOT FOUND OR v_local_codigo<>'PA' THEN RAISE EXCEPTION 'A posição informada não pertence ao estoque PA'; END IF;
 INSERT INTO public.inventario_wms_posicoes(inventario_id,endereco_wms_id,tipo_estoque) VALUES(p_inventario_id,p_endereco_wms_id,'PATIO') ON CONFLICT(inventario_id,endereco_wms_id,tipo_estoque) DO NOTHING;
 SELECT status INTO v_pos_status FROM public.inventario_wms_posicoes WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO' FOR UPDATE;
 IF v_pos_status='APROVADO' THEN RAISE EXCEPTION 'Esta posição já foi aprovada neste inventário'; END IF;
 PERFORM id FROM public.estoque_pa WHERE local_id=v_local_id AND (endereco_wms_id=p_endereco_wms_id OR id IN (SELECT item_id FROM public.inventario_wms_itens WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO')) FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.inventario_wms_itens i WHERE i.inventario_id=p_inventario_id AND i.endereco_wms_id=p_endereco_wms_id AND i.tipo_estoque='PATIO' AND (i.quantidade_contada IS NULL OR i.quantidade_contada<0)) THEN RAISE EXCEPTION 'A posição possui quantidade inválida ou negativa'; END IF;
 FOR r IN
  SELECT s.id,s.quantidade,s.reservado,s.bloqueado,s.lote,s.codigo_origem,s.produto_id,s.descricao_origem,coalesce(c.contado,0) AS contado,c.count_id
  FROM public.estoque_pa s
  LEFT JOIN LATERAL (SELECT sum(i.quantidade_contada) AS contado,min(i.id) AS count_id FROM public.inventario_wms_itens i WHERE i.inventario_id=p_inventario_id AND i.endereco_wms_id=p_endereco_wms_id AND i.tipo_estoque='PATIO' AND i.item_id=s.id AND coalesce(i.lote,'')=coalesce(s.lote,'')) c ON true
  WHERE s.local_id=v_local_id AND (s.endereco_wms_id=p_endereco_wms_id OR c.count_id IS NOT NULL) ORDER BY s.id
 LOOP
  IF r.contado<coalesce(r.reservado,0)+coalesce(r.bloqueado,0) THEN RAISE EXCEPTION 'Item PA %: a contagem é menor que a quantidade reservada/bloqueada.',r.codigo_origem; END IF;
  v_diff:=r.contado-coalesce(r.quantidade,0);
  UPDATE public.estoque_pa SET quantidade=r.contado,endereco_wms_id=p_endereco_wms_id WHERE id=r.id;
  IF v_diff<>0 THEN
   INSERT INTO public.movimentacoes_patio(operacao_uid,estoque_pa_id,tipo,quantidade,saldo_anterior,saldo_final,codigo,lote,documento,observacao,usuario_id)
   VALUES(gen_random_uuid(),r.id,CASE WHEN v_diff>0 THEN 'ENTRADA' ELSE 'SAIDA' END,abs(v_diff),coalesce(r.quantidade,0),r.contado,r.codigo_origem,r.lote,v_inv_codigo,'Ajuste de inventário WMS PA · posição conferida: '||(SELECT codigo FROM public.enderecos_wms WHERE id=p_endereco_wms_id),auth.uid());
  END IF;
  IF r.count_id IS NULL THEN
   IF coalesce(r.quantidade,0)>0 THEN
    INSERT INTO public.inventario_wms_itens(inventario_id,endereco_wms_id,tipo_estoque,item_id,lote,quantidade_contada,observacao,status,aprovado_em,quantidade_sistema,diferenca)
    VALUES(p_inventario_id,p_endereco_wms_id,'PATIO',r.id,nullif(r.lote,''),0,'NÃO LOCALIZADO NA CONTAGEM FÍSICA — saldo zerado automaticamente.','APROVADO',now(),r.quantidade,-r.quantidade);
   END IF;
  ELSE
   UPDATE public.inventario_wms_itens SET status='APROVADO',aprovado_em=now(),quantidade_sistema=r.quantidade,diferenca=v_diff WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO' AND item_id=r.id AND coalesce(lote,'')=coalesce(r.lote,'');
  END IF;
  IF r.contado=0 AND coalesce(r.quantidade,0)>0 THEN v_zerados:=v_zerados+1;v_qtd_zerada:=v_qtd_zerada+coalesce(r.quantidade,0); END IF;
  v_grupos:=v_grupos+1;
 END LOOP;
 UPDATE public.inventario_wms_posicoes SET status='APROVADO',aprovado_em=now() WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id AND tipo_estoque='PATIO';
 UPDATE public.enderecos_wms e SET status=CASE WHEN EXISTS(SELECT 1 FROM public.estoque_produto_pronto pp WHERE pp.endereco_wms_id=e.id AND pp.quantidade>0) OR EXISTS(SELECT 1 FROM public.estoque_mp mp WHERE mp.endereco_wms_id=e.id AND mp.quantidade>0) OR EXISTS(SELECT 1 FROM public.estoque_pa pa WHERE pa.endereco_wms_id=e.id AND pa.quantidade>0) THEN 'OCUPADO' ELSE 'LIVRE' END WHERE e.id=p_endereco_wms_id;
 RETURN jsonb_build_object('ok',true,'status','APROVADO','tipo_estoque','PATIO','grupos_conferidos',v_grupos,'itens_zerados',v_zerados,'quantidade_zerada',v_qtd_zerada);
END; $function$;
