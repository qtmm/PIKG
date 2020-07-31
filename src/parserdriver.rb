require_relative 'common.rb'
require_relative "intermediate_exp_class.rb"
require_relative "disassemble_statement.rb"
require_relative "kernelparser.rb"
require_relative "expand_function.rb"
require_relative "reduce_madd.rb"
require_relative "loop_fission.rb"
require_relative "software_pipelining.rb"

require_relative "A64FX.rb"
require_relative "AVX-512.rb"
require_relative "AVX2.rb"

$dimension = 3
$reserved_function = ["rsqrt","sqrt","inv","max","min","madd","msub","nmadd","nmsub","table","to_int","to_uint","to_float"]
$tmp_val_count = 0

$iotypes = ["EPI","EPJ","FORCE","MEMBER","TABLE"]
$types = ["F64","F32","F16","S64","S32","S16","U64","U32","U16","F64vec","F32vec","F16vec","F64mat","F32mat","F16mat"]
$float_scalar_types = ["F64","F32","F16"]
$modifiers = ["local"]

def accumulate_related_variable(orig,vars,h)
  ret = []
  #p orig
  if vars != nil
    ret = vars
    vars.each{ |v|
      if  h[v] != nil
        if !($varhash[v][0] =~ /(EPI|EPJ|FORCE)/)
          ret += accumulate_related_variable(v,h[v][0],h) if v != orig && h[v][1] == true
        end
        h[v][1] = false
      end
    }
  end
  ret
end

def generate_related_map2(fs,ss,h=$varhash)
  tmp = []
  fs.each{ |f|
    tmp += [f]
    #p f
    ss.reverse_each{ |s|
      var = get_name(s)
      if isStatement(s) && h[var][3] != "local"
        if tmp.find(var)
          tmp += s.expression.get_related_variable
        elsif s.class == CoditionalBranch
          tmp += s.get_related_variable
        elsif s.class == IfElseState
          p s
          abort
        end
      end
    }
    tmp.sort!.uniq!
    #p tmp
  }
  #abort
  tmp
end

def generate_related_map(fs,ss,h=$varhash)
  tmp = []
  ss.each{ |s|
    #p get_name(s),h[get_name(s)] if isStatement(s)
    if isStatement(s) && h[get_name(s)][3] != "local"
      exp = s.expression.get_related_variable
      tmp += [[get_name(s),exp]] if exp != []
    elsif s.class == ConditionalBranch
      tmp += s.get_related_variable
    end
  }
  tmp.sort!
  #tmp.sort_by{ |v| v[0]}
  tmp.uniq!

  tmp2 = Hash.new()
  tmp.each{ |v|
    if tmp2[v[0]] == nil
      tmp2[v[0]] = [v[1],true]
    else
      tmp2[v[0]][0] += v[1]
    end
  }
  tmp3 = []
  fs.each{ |f|
    tmp3 += accumulate_related_variable(f,tmp2[f][0],tmp2)
  }
  ss.each{ |s|
    tmp3 += s.expression.get_related_variable if s.class == IfElseState && s.expression != nil
    tmp3 += s.get_cond_related_variable if s.class == ConditionalBranch
  }
  ret = tmp3.sort.uniq

  ret
end

def generate_force_related_map(ss,h=$varhash)
  fs = []
  h.each{ |v|
    iotype = v[1][0]
    fs += [v[0]] if iotype == "FORCE"
  }
  ret = generate_related_map2(fs,ss,h)
  ret
end

class Kernelprogram
  def check_references
    ref_list = []
    @iodeclarations.each{ |d|
      ref_list.push(d.name)
    }
    @statements.each{ |s|
      ref_list.push(get_name(s))
      vars = s.get_related_variable
      vars.each{ |v|
        if !ref_list.index(v)
          lineno = get_lineno(v)
          line   = get_line(v)
          message = "line #{lineno} : #{line}"
          for i in 1..message.index(v)
            message += " "
          end
          message += "^\n"
          message = "error : undefined reference to \"#{v}\"\n" + message
          abort message
        end
      }
    }

    @functions.each{ |f|
      ref_list = []
      f.decl.vars.each{ |v|
        ref_list.push(v)
      }
      f.statements.each{ |s|
        ref_list.push(get_name(s))
        vars = s.get_related_variable
        vars.each{ |v|
          if !ref_list.index(v)
            lineno = get_lineno(v)
            line   = get_line(v)
            message = "line #{lineno} : #{line}"
            for i in 1..message.index(v)
              message += " "
            end
            message += "^\n"
            message = "error : undefined reference to \"#{v}\"\n" + message
            abort message
          end
        }
      }
    }
  end
  def generate_hash(kerneltype)
    #    print "print kernel\n"
    #p self
    #p $funchash
    $varhash=process_iodecl(@iodeclarations)
    $funchash=process_funcdecl(@functions)
    #p $varhash
    @statements.each{|s|
      #p s
      if isStatement(s)
        if s.name.class == Expression
          if s.name.operator == :dot
            if ["x","y","z"].index(s.name.rop)
              type = s.get_type
              s.type = type + "vec"
              s.add_to_varhash
              s.type = type
            else
              abort  "left value must be vector or scalar variable"
            end
          else
            abort "only vector expression is allowed for left value"
          end
        else
          s.get_type
          s.add_to_varhash
        end
      elsif s.class == TableDecl
        #p s
        s.add_to_varhash
      end
    }
    #reserved variables
    ["ni","nj","i","j","jj","jjj"].each{ |x|
      $varhash[x] = [nil,"S32",nil]
    }
    #p $funchash
  end
  def print_function(conversion_type)
    @functions.each{ |f|
      print f.convert_to_code(conversion_type)
    }
  end
  def print_statements(conversion_type)
    @statements.each{|s|
      #p s
      print s.convert_to_code(conversion_type)+"\n"
    }
  end
 
  def split_coefficients(orig)
    #p "split_coefficients",orig
    ret = []
    exp = orig.dup
    if !isLeaf(orig)
      if orig.operator == :mult
        lt = orig.lop.get_type
        rt = orig.rop.get_type
        if ((lt =~ /vec/) && !(rt =~ /vec/))
          #p "split candidate lop: #{orig.rop} with #{orig.lop}"
          if !isLeaf(orig.rop)
            tmp_name = add_new_tmpvar(rt)
            tmp = Statement.new([tmp_name,Expression.new([orig.rop.operator,orig.rop.lop,orig.rop.rop])])
            tmp.type = rt
            tmp.expression.type = orig.rop.get_type
            tmp.add_to_varhash
            orig = Expression.new([orig.operator,orig.lop,tmp_name,orig.type])
            ret += split_coefficients(orig.lop)
            ret.push(tmp)
          end
        elsif (!(lt =~ /vec/) && (rt =~ /vec/))
          #p "split candidate lop: #{orig.lop} with #{orig.rop}"
          if !isLeaf(orig.lop)
            tmp_name = add_new_tmpvar(lt) #"__fkg_tmp#{$tmp_val_count}"
            tmp = Statement.new([tmp_name,Expression.new([orig.lop.operator,orig.lop.lop,orig.lop.rop])])
            tmp.type = lt
            tmp.expression.type = orig.lop.get_type
            tmp.add_to_varhash
            #orig.lop = tmp_name
            orig = Expression.new([orig.operator,tmp_name,orig.rop,orig.type])
            ret += split_coefficients(orig.rop)
            ret.push(tmp)
          end
        else
          ret += split_coefficients(orig.lop)
          ret += split_coefficients(orig.rop) if orig.rop != nil
        end
      else
        ret += split_coefficients(orig.lop)
        ret += split_coefficients(orig.rop) if orig.rop != nil
      end
    else
      #if orig.class == FuncCall
      #tmp_name = "__fkg_tmp#{$tmp_val_count}"
      #tmp = Statement.new([tmp_name,orig])
      #tmp.type = orig.get_type
      #tmp.expression.type = orig.get_type
      #tmp.add_to_varhash
      #p orig.get_type
      #p tmp
      #orig = tmp_name
      #ret.push(tmp)
      #$tmp_val_count += 1
      #end
    end
    #p "return value:", ret, orig
    ret
  end

  def vector_to_scalar(exp,dim)
    #p "vector_to_scalar:"
    ret = exp.dup
    if !isLeaf(ret)
      #p ret
      ret.type = ret.type.delete("vec") if isVector(ret)
      ret.lop = vector_to_scalar(ret.lop,dim)
      ret.rop = vector_to_scalar(ret.rop,dim)
    else
      if isVector(ret)
        ret = Expression.new([:dot,ret,dim])
        ret.type = exp.get_type.delete("vec")
        #ret.type = ret.type.delete("vec")
      end
    end
    ret
  end
  
  def split_vector_expression(orig,dim = $dimension)
    ret = []
    if isVector(orig)
      if !(orig.expression.class == FuncCall)
        ["x","y","z"].each{ |d|
          val = Expression.new([:dot,orig.name,d])
          exp = vector_to_scalar(orig.expression,d)
          #p exp
          type = orig.type.delete("vec")
          tmp = Statement.new([val,exp])
          tmp.type = type
          ret.push(tmp)
        }
      else
        abort "function returns vector value is not arrowed (must be expanded before splitting)"
        ret.push(orig)
      end
    else
      ret = [orig]
    end
    ret
  end
  
  def expand_vector_statement(orig)
    ret = []
    val = orig.name
    exp = orig.expression
    ret += split_coefficients(exp)
    ret += split_vector_expression(orig)
    ret
  end

  def expand_tree
    @statements.each{ |s|
      if isStatement(s)
        s.expand_tree
      end
    }
    new_s = []
    @statements.each{ |orig|
      if isStatement(orig)
        expand_vector_statement(orig).each{ |s|
          s.reduce_madd_recursive
          s.reduce_negate_recursive
          new_s.push(s)
        }
      else
        new_s.push(orig)
      end
    }
    @statements = new_s
    #p "expanded statements:",@statements
  end

  def calc_max_predicate_count(ss)
    ret = 1
    count = 1
    ss.each{ |s|
      if s.class == IfElseState
        if s.operator == :if
          count += 1
        elsif s.operator == :endif
          count -= 1
        end
        ret = count if count > ret
      elsif s.class == ConditionalBranch
        tmp = s.calc_max_predicate_count
        ret = tmp if ret < tmp
      end
    }
    ret
  end
  
  def kernel_class_def(conversion_type)
    code = ""
    code += "struct #{$kernel_name}{\n"
    $varhash.each{|v|
      iotype = v[1][0]
      if iotype == "MEMBER"
        name = v[0]
        type = v[1][1]
        code += "PIKG::" + type + " " + name + ";\n"
      end
    }
   
    code += "#{$kernel_name}("
    member_count = 0
    $varhash.each{|v|
      iotype = v[1][0]
      if iotype == "MEMBER"
        name = v[0]
        type = v[1][1]
        code += "," if member_count > 0
        code += "PIKG::" + type + " " + name
        member_count = member_count+1
      end
    }
    code += ")"
    member_count = 0
    $varhash.each{|v|
      iotype = v[1][0]
      if iotype == "MEMBER"
        name = v[0]
        code += ":" if member_count == 0
        code += "," if member_count > 0
        code += name + "(" + name +")"
        member_count = member_count+1
      end
    }
    code += "{}\n"
    code += "void operator()(const #{$epi_name}* __restrict__ epi,const int ni,const #{$epj_name}* __restrict__ epj,const int nj,#{$force_name}* __restrict__ force){\n"
    if conversion_type =~ /(A64FX|AVX)/
      $pg_count = 0
      $current_predicate = "pg#{$pg_count}"
      $max_pg_count = calc_max_predicate_count(@statements)
      if conversion_type =~ /A64FX/
        for i in 0...$max_pg_count
          code += "svbool_t pg#{i};\n"
        end
      elsif conversion_type =~ /AVX2/
      elsif conversion_type =~ /AVX-512/
      end
    end

    code
  end

  def reserved_func_def(conversion_type)
    code = ""
    # code += "template<typename Tret,typename Top>\n"
    # code += "Tret rsqrt(Top op){ return (Tret)1.0/std::sqrt(op); }\n"
    # code += "template<typename Tret,typename Top>\n"
    # code += "Tret sqrt(Top op){ return std::sqrt(op); }\n"
    # code += "template<typename Tret,typename Top>\n"
    # code += "Tret inv(Top op){ return 1.0/op; }\n"
    # code += "template<typename Tret,typename Ta,typename Tb>\n"
    # code += "Tret max(Ta a,Tb b){ return std::max(a,b);}\n"
    # code += "template<typename Tret,typename Ta,typename Tb>\n"
    # code += "Tret min(Ta a,Tb b){ return std::min(a,b);}\n"
    code += "PIKG::F64 rsqrt(PIKG::F64 op){ return 1.0/std::sqrt(op); }\n"
    code += "PIKG::F64 sqrt(PIKG::F64 op){ return std::sqrt(op); }\n"
    code += "PIKG::F64 inv(PIKG::F64 op){ return 1.0/op; }\n"
    code += "PIKG::F64 max(PIKG::F64 a,PIKG::F64 b){ return std::max(a,b);}\n"
    code += "PIKG::F64 min(PIKG::F64 a,PIKG::F64 b){ return std::min(a,b);}\n"

    code += "PIKG::F32 rsqrt(PIKG::F32 op){ return 1.f/std::sqrt(op); }\n"
    code += "PIKG::F32 sqrt(PIKG::F32 op){ return std::sqrt(op); }\n"
    code += "PIKG::F32 inv(PIKG::F32 op){ return 1.f/op; }\n"

    code += "PIKG::S64 max(PIKG::S64 a,PIKG::S64 b){ return std::max(a,b);}\n"
    code += "PIKG::S64 min(PIKG::S64 a,PIKG::S64 b){ return std::min(a,b);}\n"
    code += "PIKG::S32 max(PIKG::S32 a,PIKG::S32 b){ return std::max(a,b);}\n"
    code += "PIKG::S32 min(PIKG::S32 a,PIKG::S32 b){ return std::min(a,b);}\n"

    code += "PIKG::F64 table(PIKG::F64 tab[],PIKG::S64 i){ return tab[i]; }\n"
    code += "PIKG::F32 table(PIKG::F32 tab[],PIKG::S32 i){ return tab[i]; }\n"

    code += "PIKG::F64 to_float(PIKG::U64 op){return (PIKG::F64)op;}\n"
    code += "PIKG::F32 to_float(PIKG::U32 op){return (PIKG::F32)op;}\n"
    code += "PIKG::F64 to_float(PIKG::S64 op){return (PIKG::F64)op;}\n"
    code += "PIKG::F32 to_float(PIKG::S32 op){return (PIKG::F32)op;}\n"
    code += "PIKG::S64   to_int(PIKG::F64 op){return (PIKG::S64)op;}\n"
    code += "PIKG::S32   to_int(PIKG::F32 op){return (PIKG::S32)op;}\n"
    code += "PIKG::U64  to_uint(PIKG::F64 op){return (PIKG::U64)op;}\n"
    code += "PIKG::U32  to_uint(PIKG::F32 op){return (PIKG::U32)op;}\n"

    #code += "PIKG::F64 table(const PIKG::F64 tab[],const PIKG::U32 index){ return tab[index];);\n"
    #code += "PIKG::F32 table(const PIKG::F32 tab[],const PIKG::U32 index){ return tab[index];);\n"
    case conversion_type
    when /A64FX/ then
      code += self.reserved_func_def_a64fx(conversion_type)
    when /AVX2/ then
      code += self.reserved_func_def_avx2(conversion_type)
    when /AVX-512/ then
      code += self.reserved_func_def_avx512(conversion_type)
    end
    code
  end

  def split_accum_statement(ss,h = $varhash)
    j_list = []
    h.each{ |v|
      iotype = v[1][0]
      if iotype == "EPJ"
        name = v[0]
        j_list += [name]
      end
    }

    init = []
    body = []
    accum = []
    ss.each{|s|
      if isStatement(s)
        name = get_name(s.name)
        if h[name][3] != "local"
          if s.expression.isJRelated(j_list)
            j_list += [name] if j_list.index(name) == nil
            body += [s]
          else
            v = h[name]
            iotype = v[0]
            case iotype
            when "FORCE"
              accum += [s]
            when nil
              init  += [s]
            else
              body  += [s]
            end
          end
        end
      else
        body += [s]
      end
    }
    [init,body,accum]
  end
  
  def aos2soa(fvars,conversion_type,h=$varhash)
    ret = []
    case conversion_type
    when "reference"
      h.each{|v|
        iotype = v[1][0]
        if iotype == "EPI" || iotype == "FORCE"
          name     = v[0]
          type     = v[1][1]
          modifier = v[1][3]
          ret += [Declaration.new([type,name])]
          if modifier == "local"
            if type =~ /vec/
              ret += [Statement.new([Expression.new([:dot,name,"x"]),Expression.new([:array,"#{name}_tmp_x",get_io_index(iotype),type]),type])]
              ret += [Statement.new([Expression.new([:dot,name,"y"]),Expression.new([:array,"#{name}_tmp_y",get_io_index(iotype),type]),type])]
              ret += [Statement.new([Expression.new([:dot,name,"z"]),Expression.new([:array,"#{name}_tmp_z",get_io_index(iotype),type]),type])]
            else
              ret += [Statement.new([name,Expression.new([:array,"#{name}_tmp",get_io_index(iotype),type]),type])]
            end
          elsif fvars.index(name)
            fdpsname = v[1][2]
            ret += [Statement.new([name,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype),type]),fdpsname,type]),type])]
          end
        end
      }
    when /(A64FX|AVX)/
      ret += aos2soa_simd(fvars,h)
    else
      abort "error: unsupported conversion_type #{conversion_type} in AoS2SoA"
    end
    ret
  end

  def soa2aos(fvars,conversion_type,h=$varhash)
    ret = []
    case conversion_type
    when "reference"
      h.each{|v|
        iotype = v[1][0]
        if iotype == "FORCE"
          name = v[0]
          type = v[1][1]
          fdpsname = v[1][2]
          if type =~ /vec/
            ret += [StoreState.new([Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype),type]),fdpsname,type]),"x"]),Expression.new([:dot,name,"x"]),type])]
            ret += [StoreState.new([Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype),type]),fdpsname,type]),"y"]),Expression.new([:dot,name,"y"]),type])]
            ret += [StoreState.new([Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype),type]),fdpsname,type]),"z"]),Expression.new([:dot,name,"z"]),type])]
          else
            ret += [StoreState.new([Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype),type]),fdpsname,type]),name,type])]
          end
        end
      }
    when /(A64FX|AVX)/
      ret += soa2aos_simd(fvars,h)
    else
      abort "error: unsupported conversion_type #{conversion_type} in SoA2AoS"
    end
    ret
  end

  def generate_iloop_begin(conversion_type,max_size_epi,istart = 0)
        
    case conversion_type
    when "reference"
      ret = Loop.new(["i",istart,"ni",1,[]])
    when  /A64FX/
      nelem = get_simd_width(conversion_type) / max_size_epi
      ret = Loop.new(["i",istart,"((ni+#{nelem-1})/#{nelem})*#{nelem}","#{nelem}",["#{$current_predicate}=svwhilelt_b32_s32(i,ni);"]])
    when  /AVX/
      nelem = get_simd_width(conversion_type) / max_size_epi
      ret = Loop.new(["i",istart,"(ni/#{nelem})*#{nelem}","#{nelem}",[]])
    end
    ret
  end
  
  def kernel_body(conversion_type,istart=0,h=$varhash)
    code = ""
    ret = []
    ret.push(NonSimdDecl.new(["S32","i"])) if istart != nil
    ret.push(NonSimdDecl.new(["S32","j"]))

    if istart != nil
      # declare "local" variables
      h.each{ |v|
        modify = v[1][3]
        if modify == "local"
          name = v[0]
          iotype = v[1][0]
          type   = v[1][1]
          array_size = ["ni","nj"][["EPI","EPJ"].index(iotype)]
          if type =~ /vec/
            type = type.delete("vec")
            ret += [Declaration.new([type,Expression.new([:array,"#{name}_tmp_x",array_size,type])])]
            ret += [Declaration.new([type,Expression.new([:array,"#{name}_tmp_y",array_size,type])])]
            ret += [Declaration.new([type,Expression.new([:array,"#{name}_tmp_z",array_size,type])])]
          else
            ret += [Declaration.new([type,Expression.new([:array,"#{name}_tmp",array_size,type])])]
          end
        end
      }

      # calc or copy local variables from EPI, EPJ, or FORCE
      @statements.each{ |s|
        name = get_name(s) if s.class == Statement
        if name != nil && h[name][3] == "local"
          tail = get_tail(s.name)
          iotype = h[name][0]
          type   = h[name][1]
          exp = s.expression
          index = get_io_index(iotype)
          loop_tmp = Loop.new([index,"0","n#{index}",1,[]])
          if tail != nil
            new_name = Expression.new([:array,"#{name}_tmp_#{tail}",index,type])
          else
            new_name = Expression.new([:array,"#{name}_tmp",index,type]) #"#{name}_tmp[i]"
          end
          new_exp = exp.replace_fdpsname_recursive(h)
          loop_tmp.statements += [Statement.new([new_name,new_exp])]
          ret += [loop_tmp]
        end
      }
    end
    ret.each{ |s|
      code += s.convert_to_code("reference")
    }
    ret = []

    # declare and load TABLE variable
    tmp = []
    @statements.each{ |s|
      if s.class == TableDecl
        ret.push(s)
        tmp.push(s)
      end
    }
    tmp.each{ |s|
      @statements.delete(s)
    }

    # declare temporal variables
    @statements.each{ |s|
      if s.class == Statement || s.class == ConditionalBranch
        ret += s.declare_temporal_var
      end
    }
    # check maximum size of EPI variable
    max_size_epi = -1
    h.each{ |v|
      iotype = v[1][0]
      if iotype == "EPI"
        type = v[1][1]
        size = get_data_size(type)
        max_size_epi = size if size > max_size_epi
      end
    }
    max_size_epi = 64 if max_size_epi > 64
    # building i loop
    accum_init,ss,accum_finalize = split_accum_statement(@statements)
    fvars = generate_force_related_map(ss)
    iloop = generate_iloop_begin(conversion_type,max_size_epi,istart)

    # load EPI and FORCE variable
    iloop.statements += aos2soa(fvars,conversion_type)

    accum_init.each{|s|
      iloop.statements += [s]
    }

    iloop.statements += [NonSimdState.new(["j","0"])]
    if $strip_mining != nil
      warn "strip mining is applied"
      loop_fission_vars = find_loop_fission_load_store_vars(ss)
      fission_count = 0
      tmpvars = []
      loop_fission_vars.each{ |vs|
        vs[0].each{ |v|
          tmpvars += [v]
        }
      }
      tmpvars.uniq.each{ |v|
        iotype = $varhash[v][0]
        type = $varhash[v][1]
        if type =~ /vec/
          type = type.delete("vec")
          iloop.statements += [NonSimdDecl.new([type,"#{v}_tmp_x[#{nsimd}*#{$strip_mining}]"])]
          iloop.statements += [NonSimdDecl.new([type,"#{v}_tmp_y[#{nsimd}*#{$strip_mining}]"])]
          iloop.statements += [NonSimdDecl.new([type,"#{v}_tmp_z[#{nsimd}*#{$strip_mining}]"])]
        else
          iloop.statements += [NonSimdDecl.new([type,"#{v}_tmp[#{nsimd}*#{$strip_mining}]"])]
        end
      }

      jloop = Loop.new(["j",nil,"(nj/#{$strip_mining})*#{$strip_mining}","#{$strip_mining}",[NonSimdDecl.new(["S32","jj"])]])
      jjloop = Loop.new(["jj","0","#{$strip_mining}",1,[]])
      jjj = NonSimdExp.new([:plus,"j","jj"])
      first_loop = true
      ss.each{ |s|
        $unroll_stage = s.option[0].to_i if s.class == Pragma && s.name == "unroll"

        if (s.class == Pragma && s.name == "statement" && s.option == ["loop_fission_point"])|| first_loop
          if !first_loop
            loop_fission_vars[fission_count][0].each{ |v|
              type = h[v][1]
              if type =~ /vec/
                jjloop.statements += [StoreState.new([PointerOf.new([type,Expression.new([:array,"#{v}_tmp_x",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),Expression.new([:dot,"#{v}","x"]),type])]
                jjloop.statements += [StoreState.new([PointerOf.new([type,Expression.new([:array,"#{v}_tmp_y",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),Expression.new([:dot,"#{v}","y"]),type])]
                jjloop.statements += [StoreState.new([PointerOf.new([type,Expression.new([:array,"#{v}_tmp_z",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),Expression.new([:dot,"#{v}","z"]),type])]
              else
                jjloop.statements += [StoreState.new([PointerOf.new([type,Expression.new([:array,"#{v}_tmp",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),"#{v}",type])]
              end
            }
            #jjloop = software_pipelining(jjloop) if $swpl_stage > 1
            jjloop = loop_unroll(jjloop,$unroll_stage) if $unroll_stage > 1
            jloop.statements += [jjloop.dup]
          end
          first_loop = false
          jjloop = Loop.new(["jj","0","#{$strip_mining}",1,[]])

          loop_fission_vars[fission_count][1].each{ |v|
            iotype = h[v][0]
            type   = h[v][1]
            if iotype == "declared"
              if type =~ /vec/
                jjloop.statements += [LoadState.new([Expression.new([:dot,"#{v}","x"]),PointerOf.new([type,Expression.new([:array,"#{v}_tmp_x",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),type])]
                jjloop.statements += [LoadState.new([Expression.new([:dot,"#{v}","y"]),PointerOf.new([type,Expression.new([:array,"#{v}_tmp_y",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),type])]
                jjloop.statements += [LoadState.new([Expression.new([:dot,"#{v}","z"]),PointerOf.new([type,Expression.new([:array,"#{v}_tmp_z",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),type])]
              else
                jjloop.statements += [LoadState.new(["#{v}",PointerOf.new([type,Expression.new([:array,"#{v}_tmp",NonSimdExp.new([:mult,"#{nsimd}","jj","S32"])])]),type])]
              end
            elsif iotype == "EPJ"
              name     = v
              fdpsname = h[v][2]
              modifier = h[v][3]

              jjloop.statements += [Declaration.new([type,name])]
              case modifier
              when "local"
                if type =~ /vec/
                  jjloop.statements += [Duplicate.new([Expression.new([:dot,name,"x"]),Expression.new([:array,"#{name}_tmp_x",jjj,type]),type])]
                  jjloop.statements += [Duplicate.new([Expression.new([:dot,name,"y"]),Expression.new([:array,"#{name}_tmp_y",jjj,type]),type])]
                  jjloop.statements += [Duplicate.new([Expression.new([:dot,name,"z"]),Expression.new([:array,"#{name}_tmp_z",jjj,type]),type])] 
                else
                  jjloop.statements += [Duplicate.new([name,Expression.new([:array,"#{name}_tmp",jjj,type]),type])]
                end
              else
                if type =~ /vec/
                  stype = type.delete("vec")
                  jjloop.statements += [Statement.new([Expression.new([:dot,name,"x"]),Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),jjj]),fdpsname,type]),"x"]),stype])]
                  jjloop.statements += [Statement.new([Expression.new([:dot,name,"y"]),Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),jjj]),fdpsname,type]),"y"]),stype])]
                  jjloop.statements += [Statement.new([Expression.new([:dot,name,"z"]),Expression.new([:dot,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),jjj]),fdpsname,type]),"z"]),stype])]
                else
                  jjloop.statements += [Statement.new([name,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),jjj]),fdpsname,type]),type])]
                end
              end
            elsif fvars.index(name)
              fdpsname = v[1][2]
              jjloop.statements += [Duplicate.new([name,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype)]),fdpsname,type]),type])]
            end
          }
          fission_count += 1
        end # s.class != Pragma
        jjloop.statements += [s] if (!isStatement(s) || h[get_name(s)][3] != "local") && s.class != Pragma
      } # ss.each
      #jjloop = software_pipelining(jjloop) if $swpl_stage > 1
      jjloop = loop_unroll(jjloop,$unroll_stage) if $unroll_stage > 1
      jloop.statements += [jjloop.dup]

      iloop.statements += [jloop]
    end # strip_mining

    # tail j loop
    jloop = Loop.new(["j",nil,"nj",1,[]])
    fvars.each{|v|
      iotype = h[v][0]
      if iotype == "EPJ"
        name     = v
        type     = h[v][1]
        modifier = h[v][3]
        jloop.statements += [Declaration.new([type,name])]
        if modifier == "local"
          if type =~ /vec/
            jloop.statements += [Duplicate.new([Expression.new([:dot,name,"x"]),Expression.new([:array,"#{name}_tmp_x",get_io_index(iotype),type]),type])]
            jloop.statements += [Duplicate.new([Expression.new([:dot,name,"y"]),Expression.new([:array,"#{name}_tmp_y",get_io_index(iotype),type]),type])]
            jloop.statements += [Duplicate.new([Expression.new([:dot,name,"z"]),Expression.new([:array,"#{name}_tmp_z",get_io_index(iotype),type]),type])]
          else
            jloop.statements += [Duplicate.new([name,Expression.new([:array,"#{name}_tmp",get_io_index(iotype),type]),type])]
          end
        elsif fvars.index(name)
          fdpsname = h[v][2]
          jloop.statements += [Statement.new([name,Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),get_io_index(iotype)]),fdpsname,type]),type])]
        end
      end
    }
    ss.each{|s|
      jloop.statements += [s] if s.class != Pragma
    }
    iloop.statements += [jloop]

    accum_finalize.each{|s|
      iloop.statements += [s]
    }
    iloop.statements += soa2aos(fvars,conversion_type)

    ret += [iloop]
    ret.each{ |s|
      code += s.convert_to_code(conversion_type)
    }

    # tail i loop
    if conversion_type =~ /AVX/
      h.each{|v|
        iotype   = v[1][0]
        v[1][0] = nil if iotype == "declared"
      }
      code += "{\n"
      code += kernel_body("reference",nil)
      code += "}\n"
    end
    
    code
  end
  def generate_optimized_code(conversion_type,output=$output_file)
    code = "#include<pikg_vector.hpp>\n"
    case conversion_type
    when /A64FX/
      code += "#include <arm_sve.h>\n"
    when /AVX2/
      code += "#ifndef H_PIKG_AVX2\n"
      code += "#define H_PIKG_AVX2\n"
      code += "#include <immintrin.h>\n"
      code += "struct __m256dx2{\n"
      code += "  __m256d v0,v1;\n"
      code += "};\n"
      code += "struct __m256dx3{\n"
      code += "  __m256d v0,v1,v2;\n"
      code += "};\n"
      code += "struct __m256dx4{\n"
      code += "  __m256d v0,v1,v2,v3;\n"
      code += "};\n"
      code += "struct __m256x2{\n"
      code += "  __m256 v0,v1;\n"
      code += "};\n"
      code += "struct __m256x3{\n"
      code += "  __m256 v0,v1,v2;\n"
      code += "};\n"
      code += "struct __m256x4{\n"
      code += "  __m256 v0,v1,v2,v3;\n"
      code += "};\n"

      code += "__m256dx2 _mm256_set1_pdx2(const PIKG::F64vec2 v){\n"
      code += "  __m256dx2 ret;\n"
      code += "  ret.v0 = _mm256_set1_pd(v.x);\n"
      code += "  ret.v1 = _mm256_set1_pd(v.y);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m256x2  _mm256_set1_psx2(const PIKG::F32vec2 v){\n"
      code += "  __m256x2 ret;\n"
      code += "  ret.v0 = _mm256_set1_ps(v.x);\n"
      code += "  ret.v1 = _mm256_set1_ps(v.y);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m256dx3 _mm256_set1_pdx3(const PIKG::F64vec v){\n"
      code += "  __m256dx3 ret;\n"
      code += "  ret.v0 = _mm256_set1_pd(v.x);\n"
      code += "  ret.v1 = _mm256_set1_pd(v.y);\n"
      code += "  ret.v2 = _mm256_set1_pd(v.z);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m256x3  _mm256_set1_psx3(const PIKG::F32vec v){\n"
      code += "  __m256x3 ret;\n"
      code += "  ret.v0 = _mm256_set1_ps(v.x);\n"
      code += "  ret.v1 = _mm256_set1_ps(v.y);\n"
      code += "  ret.v2 = _mm256_set1_ps(v.z);\n"
      code += "  return ret;\n"
      code += "}\n"
      #code += "__m256dx4 _mm256_set1_pdx3(const PIKG::F64vec4& v){\n"
      #code += "  __m256dx4 ret;\n"
      #code += "  ret.v0 = _mm256_set1_pd(v.x);\n"
      #code += "  ret.v1 = _mm256_set1_pd(v.y);\n"
      #code += "  ret.v2 = _mm256_set1_pd(v.z);\n"
      #code += "  ret.v3 = _mm256_set1_pd(v.w);\n"
      #code += "  return ret;\n"
      #code += "}\n"
      #code += "__m256x4  _mm256_set1_psx3(const PIKG::F32vec4& v){\n"
      #code += "  __m256x4 ret;\n"
      #code += "  ret.v0 = _mm256_set1_ps(v.x);\n"
      #code += "  ret.v1 = _mm256_set1_ps(v.y);\n"
      #code += "  ret.v2 = _mm256_set1_ps(v.z);\n"
      #code += "  ret.v3 = _mm256_set1_ps(v.w);\n"
      #code += "  return ret;\n"
      #code += "}\n"
      code += "#endif\n"
    when /AVX-512/
      code += "#ifndef H_PIKG_AVX_512\n"
      code += "#define H_PIKG_AVX_512\n"
      code += "#include <immintrin.h>\n"
      code += "struct __m512dx2{\n"
      code += "  __m512d v0,v1;\n"
      code += "};\n"
      code += "struct __m512dx3{\n"
      code += "  __m512d v0,v1,v2;\n"
      code += "};\n"
      code += "struct __m512dx4{\n"
      code += "  __m512d v0,v1,v2,v3;\n"
      code += "};\n"
      code += "struct __m512x2{\n"
      code += "  __m512 v0,v1;\n"
      code += "};\n"
      code += "struct __m512x3{\n"
      code += "  __m512 v0,v1,v2;\n"
      code += "};\n"
      code += "struct __m512x4{\n"
      code += "  __m512 v0,v1,v2,v3;\n"
      code += "};\n"

      code += "__m512dx2 _mm512_set1_pdx2(const PIKG::F64vec2 v){\n"
      code += "  __m512dx2 ret;\n"
      code += "  ret.v0 = _mm512_set1_pd(v.x);\n"
      code += "  ret.v1 = _mm512_set1_pd(v.y);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m512x2  _mm512_set1_psx2(const PIKG::F32vec2 v){\n"
      code += "  __m512x2 ret;\n"
      code += "  ret.v0 = _mm512_set1_ps(v.x);\n"
      code += "  ret.v1 = _mm512_set1_ps(v.y);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m512dx3 _mm512_set1_pdx3(const PIKG::F64vec v){\n"
      code += "  __m512dx3 ret;\n"
      code += "  ret.v0 = _mm512_set1_pd(v.x);\n"
      code += "  ret.v1 = _mm512_set1_pd(v.y);\n"
      code += "  ret.v2 = _mm512_set1_pd(v.z);\n"
      code += "  return ret;\n"
      code += "}\n"
      code += "__m512x3  _mm512_set1_psx3(const PIKG::F32vec v){\n"
      code += "  __m512x3 ret;\n"
      code += "  ret.v0 = _mm512_set1_ps(v.x);\n"
      code += "  ret.v1 = _mm512_set1_ps(v.y);\n"
      code += "  ret.v2 = _mm512_set1_ps(v.z);\n"
      code += "  return ret;\n"
      code += "}\n"
      
      code += "#endif\n"
    end
    #code += "#include \"user_defined_class.h\"\n"
    code += kernel_class_def(conversion_type)
    code += kernel_body(conversion_type)
    code += "}\n"
    code += reserved_func_def(conversion_type)
    code += "};\n"

    if output == nil
      print code
    else
      File.open(output, mode = 'w'){ |f|
        f.write(code)
      }
    end
  end

  def make_conditional_branch_block(h = $varhash)
    @statements = make_conditional_branch_block_recursive2(@statements,h)
  end

  def make_conditional_branch_block_recursive2(ss,h = $varhash,related_vars = [])
    #p h
    new_s = []
    nest_level = 0
    cbb = ConditionalBranch.new([[],[]])

    ss.reverse_each { |s|
      if s.class == IfElseState
        nest_level -= 1 if s.operator == :if
        nest_level += 1 if s.operator == :endif
        abort "nest level < 0" if nest_level < 0
      end
      #p s
      if nest_level == 0
        related_vars.push(get_name(s)) if isStatement(s)
        related_vars += s.expression.get_related_variable

        #p related_vars
        related_vars.sort!.uniq!
        # push new conditional branch block
        if s.class == IfElseState
          abort "operator #{s.operator} must be :if" if s.operator != :if
          cbb.push_condition(s)

          new_b = []
          new_c = []
          cbb.bodies.reverse_each{ |b|
            b.reverse!
            new_b.push(make_conditional_branch_block_recursive2(b,h,related_vars))
          }
          cbb.conditions.reverse_each{ |c|
            new_c.push(c)
          }
          cbb.bodies = new_b
          cbb.conditions.reverse!

          new_s.push(cbb)

          # make tmp var hash
          tmp_name_hash = Hash.new()
          merge_state = []
          cbb.bodies.each{ |bss|
            bss.each { |bs|
              if isStatement(bs) && bs.expression.class != Merge
                name = get_name(bs)
                tail = get_tail(bs)
                if related_vars.find(){ |n| n == name } || h[name][0] == "FORCE"
                  tmp_name_hash[name] = add_new_tmpvar(bs.type) if tmp_name_hash[name] == nil
                  bss.push(Statement.new([name,Merge.new([tmp_name_hash[name],name,bs.type]),bs.type]))
                end
              end
            }
          }

          #p tmp_name_hash
          cbb.bodies.each{  |bss|
            computed_list = []
            replaced_list = []
            bss.each{ |bs|
              if isStatement(bs) && bs.expression.class != Merge
                name = get_name(bs)
                bs.replace_name(name,tmp_name_hash[name]) if tmp_name_hash[name] != nil
                bs.expression.replace_by_list(computed_list,replaced_list)
                if tmp_name_hash[name] != nil
                  computed_list.push(name)
                  replaced_list.push(tmp_name_hash[name])
                end
              end
            }
          }
          cbb = ConditionalBranch.new([[],[]])
        else
          new_s.push(s)
        end

      elsif nest_level > 0
        if s.class == IfElseState
          case s.operator
          when :if
            cbb.push_condition(s)
          when :elsif
            cbb.push_condition(s)
            cbb.init_new_body
          when :endif
            cbb.init_new_body
          end
        else
          cbb.push_body(s)
        end
      end
    }
    abort "ConditionalBranch is not terminated" if nest_level > 0
    new_s.reverse
  end

  def make_conditional_branch_block_recursive(ss)
    #abort "make_conditional_branch_block_recursive"
    new_s = []
    nest_level = 0
    cbb = ConditionalBranch.new([[],[]])
    computed_vars = []

    ss.each{ |s|
      if s.class == IfElseState
        nest_level += 1 if s.operator == :if
        nest_level -= 1 if s.operator == :endif
        abort "nest level is less than 0" if nest_level < 0
      end
      if nest_level == 0
        if isStatement(s)
          computed_vars.push(get_name(s))
        end
        if s.class == IfElseState
          abort "operator #{s.operator} of #{s} must be :endif" if s.operator != :endif
          new_b = []
          cbb.bodies.each{ |b|
            new_b.push(make_conditional_branch_block_recursive(b))
          }
          cbb.bodies = new_b
          new_s.push(cbb)
          cbb.bodies.each{ |bss|
            name_list = []
            replaced_list = []
            bss.each{ |bs|
              if isStatement(bs) && bs.expression.class != Merge
                name = get_name(bs)
                tail = get_tail(bs)
                if computed_vars.find(){ |n| n == name }
                  abort "merging after conditional branch is not supported for vector variable" if bs.type =~  /vec/
                  tmp_name = name_list.find{ |n| n == name }
                  tmp_name = add_new_tmpvar(bs.type) if tmp_name == nil

                  bs.replace_name(name,tmp_name)
                  bs.expression.replace_by_list(name_list,replaced_list)
                  if !(name_list.find{ |n| n == name })
                    name_list.push(name)
                    replaced_list.push(tmp_name)
                  end
                  bss.push(Statement.new([name,Merge.new([tmp_name,name,bs.type]),bs.type]))
                end
              end
            }
          }
          cbb = ConditionalBranch.new([[],[]])
        else
          new_s.push(s)
        end
      elsif nest_level == 1
        if s.class == IfElseState && s.operator != :endif
          cbb.push_condition(s)
          #p cbb
        else
          cbb.push_body(s)
        end
      else
        cbb.push_body(s)
      end
    }
    abort "ConditionalBranch is not terminated" if nest_level > 0
    new_s
  end
end

class String
  def get_type(h = $varhash)
    propaties=h[self]
    if propaties
      propaties[1]
    else
      p h[self]
      p self
      nil[0]
      abort "undefined reference to #{self} at get_type of String class"
    end
  end

  def get_related_variable
    [self]
  end
  def isJRelated(list)
    if list.index(self)
      true
    else
      false
    end
  end

  def replace_recursive(orig,replaced)
    if self == orig
      replaced
    else
      self
    end
  end
  def replace_fdpsname_recursive(h=$varhash)
    name = self.dup
    ret = name
    return ret if h[name] == nil
    iotype = h[name][0]
    type = h[name][1]
    fdpsname = h[name][2]
    if iotype != nil && fdpsname != nil
      op = "i" if iotype == "EPI" || iotype == "FORCE"
      op = "j" if iotype == "EPJ"
      ret = Expression.new([:dot,Expression.new([:array,get_iotype_array(iotype),op]),fdpsname,type])
    end
    ret
  end
  
  def convert_to_code(conversion_type,h=$varhash)
    s=self
    #print "convert to code #{s}\n"
    #p $varhash[self]
    case conversion_type
    when "reference" then
      # nothing to do
    when /A64FX/
      s = self.convert_to_code_a64fx(h)
    when /AVX2/
      s = self.convert_to_code_avx2(h)
    when /AVX-512/
      s = self.convert_to_code_avx512(h)
    end
    #    print "result=", s, "\n"
    s
  end
end


def process_iodecl(ios)
  a=[]
  ios.each{|x|
    a +=  [x.name, [x.iotype, x.type, x.fdpsname, x.modifier]]
  }
  #p a
  Hash[*a]
end

def process_funcdecl(func)
  a=[]
  func.each{|x|
    decl = x.decl
    stmt = x.statements
    ret  = x.retval
    a += [decl.name, x]
  }
  # reserved name function

  Hash[*a]
end

parser=KernelParser.new
$kernel_name="Kernel"
$epi_name="EPI"
$epj_name="EPJ"
$force_name="Force"
$conversion_type = "reference"
$swpl_stage = 1
$unroll_stage = 1
while true
  opt = ARGV.shift
  break if opt == nil
  case opt
  when "-i"
    filename = ARGV.shift
    warn "input file: #{filename}\n"
  when "--kernel-name"
    $kernel_name = ARGV.shift
    warn "kernel name: #{$kernel_name}\n"
  when "--epi-name"
    $epi_name = ARGV.shift
    warn "epi name: #{$epi_name}\n"
  when "--epj-name"
    $epj_name = ARGV.shift
    warn "epj name: #{$epj_name}\n"
  when "--spj-name"
    $spj_name = ARGV.shift
    warn "spj name: #{$spj_name}\n"
  when "--force-name"
    $force_name = ARGV.shift
    warn "force name: #{$force_name}\n"
  when "--conversion-type"
    $conversion_type = ARGV.shift
    warn "conversion type: #{$conversion_type}\n"
  when "--strip-mining"
    $strip_mining = ARGV.shift
    warn "strip mining size: #{$strip_mining}\n"
  when "--software-pipelining"
    $swpl_stage = ARGV.shift.to_i
    abort "software pipelining is not available"
    warn "software pipelining stage: #{$swpl_stage}\n"
  when "--unroll"
    $unroll_stage = ARGV.shift.to_i
    warn "software pipelining stage: #{$unroll_stage}\n"
  when "--output"
    $output_file = ARGV.shift
    warn "output file name: #{$output_file}\n"
  when "--multiwalk"
    $is_multi_walk = true
    warn "multi walk mode\n"
  else
    abort "error: unsupported option #{opt}"
  end
end
#abort "output file must be specified with --output option" if $output_file == nil

src = ""
program=parser.parse(filename)

program.check_references

program.generate_hash("noconversion")
program.expand_function
program.expand_tree
program.make_conditional_branch_block
program.disassemble_statement
if $is_multi_walk
  program.generate_optimized_code_multi_walk($conversion_type);
else
  program.generate_optimized_code($conversion_type)
end

__END__