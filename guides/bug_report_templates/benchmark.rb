# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  git_source(:github) { |repo| "https://github.com/#{repo}.git" }

  gem "rails", path: "../rails", require: "rails/all"
  gem "benchmark-ips"
  gem "benchmark-memory", require: "benchmark/memory"
end

module ActionDispatch
  module Journey
    module GTG
      class Builder
        def fast_transition_table
          dtrans   = TransitionTable.new
          marked   = {}
          state_id = Hash.new { |h, k| h[k] = h.length }
          dstates = [fast_firstpos(root)]

          until dstates.empty?
            s = dstates.shift
            next if marked[s]
            marked[s] = true # mark s

            s.group_by { |state| fast_symbol(state) }.each do |sym, ps|
              u = ps.flat_map { |l| fast_followpos_table[l] }
              next if u.empty?

              from = state_id[s]

              if u.all? { |pos| pos == DUMMY }
                to   = state_id[Object.new]
                dtrans[from, to] = sym
                dtrans.add_accepting(to)

                ps.each { |state| dtrans.add_memo(to, state.memo) }
              else
                to = state_id[u]
                dtrans[from, to] = sym

                if u.include?(DUMMY)
                  ps.each do |state|
                    if fast_followpos_table[state].include?(DUMMY)
                      dtrans.add_memo(to, state.memo)
                    end
                  end

                  dtrans.add_accepting(to)
                end
              end

              dstates << u
            end
          end

          dtrans
        end

        def fast_symbol(edge)
          edge.is_a?(Journey::Nodes::Symbol) ? edge.regexp : edge.left
        end

        def fast_firstpos(node)
          case node
          when Nodes::Star
            fast_firstpos(node.left)
          when Nodes::Cat
            if nullable?(node.left)
              fast_firstpos(node.left) | fast_firstpos(node.right)
            else
              fast_firstpos(node.left)
            end
          when Nodes::Or
            node.children.flat_map { |c| fast_firstpos(c) }.tap(&:uniq!)
          when Nodes::Unary
            fast_firstpos(node.left)
          when Nodes::Terminal
            nullable?(node) ? [] : [node]
          else
            raise ArgumentError, "unknown firstpos: %s" % node.class.name
          end
        end

        def fast_lastpos(node)
          case node
          when Nodes::Star
            fast_firstpos(node.left)
          when Nodes::Or
            node.children.flat_map { |c| fast_lastpos(c) }.tap(&:uniq!)
          when Nodes::Cat
            if nullable?(node.right)
              fast_lastpos(node.left) | fast_lastpos(node.right)
            else
              fast_lastpos(node.right)
            end
          when Nodes::Terminal
            nullable?(node) ? [] : [node]
          when Nodes::Unary
            fast_lastpos(node.left)
          else
            raise ArgumentError, "unknown lastpos: %s" % node.class.name
          end
        end

        def fast_followpos_table
          return @followpos unless @followpos.nil?

          @followpos = Hash.new { |h, k| h[k] = [] }

          @ast.each do |n|
            case n
            when Nodes::Cat
              fast_lastpos(n.left).each do |i|
                @followpos[i] += fast_firstpos(n.right)
              end
            when Nodes::Star
              fast_lastpos(n).each do |i|
                @followpos[i] += fast_firstpos(n)
              end
            end
          end

          @followpos
        end
      end
    end
  end
end

route_set = ActionDispatch::Routing::RouteSet.new
route_set.draw do
  resources :users do
    resources :blogs do
      resources :posts do
        resources :comments
      end
    end
  end
end
router = route_set.router
builder = ActionDispatch::Journey::GTG::Builder.new(router.send(:ast))

Benchmark.ips do |x|
  x.report("transition_table")      { builder.transition_table }
  x.report("fast_transition_table") { builder.fast_transition_table }
  x.compare!
end

Benchmark.memory do |x|
  x.report("transition_table")      { builder.transition_table }
  x.report("fast_transition_table") { builder.fast_transition_table }
  x.compare!
end
