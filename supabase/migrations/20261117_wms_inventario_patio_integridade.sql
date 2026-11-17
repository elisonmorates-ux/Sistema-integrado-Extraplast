-- Impede que o mesmo registro do estoque PA seja contado em duas posições
-- diferentes dentro da mesma sessão de inventário.
CREATE OR REPLACE FUNCTION public.registrar_contagem_inventario_pa(
  p_inventario_id bigint,
  p_endereco_wms_id bigint,
  p_estoque_pa_id bigint,
  p_lote text,
  p_quantidade numeric,
  p_observacao text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'pg_catalog','public'
AS $function$
DECLARE
  v_local_id bigint;
  v_lote text;
  v_id bigint;
BEGIN
  IF p_quantidade IS NULL OR p_quantidade<0 THEN RAISE EXCEPTION 'A quantidade contada não pode ser negativa'; END IF;
  SELECT e.local_id,upper(l.codigo) INTO v_local_id,v_lote
  FROM public.enderecos_wms e JOIN public.locais_estoque l ON l.id=e.local_id
  WHERE e.id=p_endereco_wms_id AND e.ativo IS DISTINCT FROM false;
  IF NOT FOUND OR v_lote<>'PA' THEN RAISE EXCEPTION 'Posição informada não pertence ao PA'; END IF;
  PERFORM public.registrar_posicao_inventario_pa(p_inventario_id,p_endereco_wms_id);
  SELECT lote INTO v_lote FROM public.estoque_pa
  WHERE id=p_estoque_pa_id AND local_id=v_local_id
    AND (endereco_wms_id IS NULL OR endereco_wms_id=p_endereco_wms_id) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado no estoque PA ou já endereçado em outra posição'; END IF;
  IF coalesce(v_lote,'')<>coalesce(p_lote,'') THEN RAISE EXCEPTION 'O lote do item foi alterado. Atualize a tela e tente novamente.'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventario_wms_itens WHERE inventario_id=p_inventario_id AND tipo_estoque='PATIO' AND item_id=p_estoque_pa_id AND endereco_wms_id<>p_endereco_wms_id) THEN
    RAISE EXCEPTION 'Este registro do Pátio já foi contado em outra posição desta sessão';
  END IF;
  SELECT id INTO v_id FROM public.inventario_wms_itens
  WHERE inventario_id=p_inventario_id AND endereco_wms_id=p_endereco_wms_id
    AND tipo_estoque='PATIO' AND item_id=p_estoque_pa_id
    AND coalesce(lote,'')=coalesce(p_lote,'')
  ORDER BY id LIMIT 1 FOR UPDATE;
  IF v_id IS NULL THEN
    INSERT INTO public.inventario_wms_itens(inventario_id,endereco_wms_id,tipo_estoque,item_id,lote,quantidade_contada,observacao,status)
    VALUES(p_inventario_id,p_endereco_wms_id,'PATIO',p_estoque_pa_id,nullif(p_lote,''),p_quantidade,p_observacao,'PENDENTE')
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.inventario_wms_itens
    SET quantidade_contada=coalesce(quantidade_contada,0)+p_quantidade,
      observacao=CASE WHEN nullif(btrim(coalesce(p_observacao,'')),'') IS NULL THEN observacao WHEN nullif(btrim(coalesce(observacao,'')),'') IS NULL THEN p_observacao ELSE observacao||' | '||p_observacao END,
      status='PENDENTE',aprovado_em=NULL,quantidade_sistema=NULL,diferenca=NULL,contado_em=now()
    WHERE id=v_id;
  END IF;
  RETURN jsonb_build_object('ok',true,'contagem_id',v_id,'quantidade_adicionada',p_quantidade);
END;
$function$;